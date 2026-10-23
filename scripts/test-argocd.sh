#!/usr/bin/env bash
# ARGOCD=on: check what OpenSlice orders may deploy through Argo CD (scripts/argocd.sh and
# manifests/argocd-access.yaml), then order a chart: service order -> OSOM -> CRIDGE ->
# Application in the order's namespace -> Argo CD -> the chart's Pods, status back to OpenSlice,
# then termination. Uses OSL_URL/OSL_USER/OSL_PASSWORD, which openslice-local.sh provides.
source "$(dirname "$0")/lib.sh"
source "$ROOT/scripts/osl.sh"
source "$ROOT/scripts/argocd.sh"
need kubectl jq curl openssl

: "${OSL_URL:?}" "${OSL_USER:?}" "${OSL_PASSWORD:?}"
osl_login

# How CRIDGE names Argo CD's Application CRD for this cluster.
RSPEC="Application@argoproj.io/v1alpha1@k3d-$CLUSTER_NAME@https://$COLONIES_NODE_HOST:6443/"
TAG="devstack-$CLUSTER_NAME-$(date +%s)"
AS=(--as=system:serviceaccount:cridge:cridge)
order_id() { openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'; }
# Namespaces named like order IDs: CHECK for the checks, DEST for the ordered chart. A real
# service specification deploys into its own order's namespace, which a pre-provision LCM rule
# writes into the Application (README); the test cannot know the order ID in advance.
CHECK="$(order_id)"
DEST="$(order_id)"
# An order namespace by CRIDGE's label only.
LABELLED=devstack-argocd-test
rfss="" cfss="" order="" passed=false failures=0

app_healthy() { [[ "$(kubectl -n "$order" get applications -o jsonpath='{.items[*].status.health.status}')" == Healthy ]]; }
app_gone() { [[ -z "$(kubectl -n "$order" get applications -o name 2>/dev/null)" ]]; }
chart_up() { [[ "$(kubectl -n "$DEST" get deployments -o jsonpath='{.items[*].status.availableReplicas}')" == 1 ]]; }
chart_gone() { [[ -z "$(kubectl -n "$DEST" get deployments -o name 2>/dev/null)" ]]; }
order_completed() { [[ "$(osl GET "/serviceOrdering/v4/serviceOrder/$order" | jq -r .state)" == COMPLETED ]]; }
rspec_published() {
	osl GET "/resourceCatalogManagement/v4/resourceSpecification" | jq -e --arg n "$RSPEC" 'any(.[]; .name == $n)' >/dev/null
}

# Runs on success and on failure. Best effort; the test's own exit status is kept.
cleanup() {
	local spec
	set +e
	if [[ "$passed" != true && -n "$order" ]]; then
		{
			echo "--- Applications in $order"
			kubectl -n "$order" get applications -o json 2>&1 |
				jq -r '.items[]? | "\(.metadata.name): health=\(.status.health.status) sync=\(.status.sync.status)",
					(.status.conditions[]? | "  \(.type): \(.message)"),
					(.status.operationState.message // empty | "  operation: \(.)")'
			echo "--- kubectl -n openslice logs deploy/openslice-cridge --tail 20"
			kubectl -n openslice logs deploy/openslice-cridge --tail 20 2>&1
		} | mask_secrets >&2
		osl_terminate "$TAG" >/dev/null 2>&1 || warn "could not terminate the services of order $order in $OSL_URL"
		for _ in $(seq 30); do app_gone && break; sleep 2; done
		kubectl delete namespace "$order" --ignore-not-found --wait=false >/dev/null 2>&1
	fi
	for spec in $cfss $rfss; do
		osl DELETE "/serviceCatalogManagement/v4/serviceSpecification/$spec" >/dev/null 2>&1 ||
			warn "could not delete service specification $spec from $OSL_URL; remove it by hand"
	done
	kubectl delete namespace "$CHECK" "$DEST" "$LABELLED" --ignore-not-found --wait=false >/dev/null 2>&1
	# The project again without the test's repository, and the Pod policy with the settings' exceptions.
	argocd_project
	argocd_access
}
trap cleanup EXIT

# report <want> <got> <what> [why]
report() {
	if [[ "$2" == "$1" ]]; then
		ok "$3: ${2/deny/refus}ed${4:+ ($4)}"
	else
		warn "$3: ${2/deny/refus}ed${4:+ ($4)}, expected ${1/deny/refus}ed"
		failures=$((failures + 1))
	fi
}

# dry_run <want> <what> <policy> <kubectl args...>: a server-side dry run of the JSON object on
# stdin; only a refusal by RBAC or the ValidatingAdmissionPolicy <policy> counts as refused.
dry_run() {
	local want=$1 what=$2 policy=$3 out msg
	shift 3
	if out="$(kubectl "$@" create --dry-run=server -f - 2>&1)"; then
		report "$want" allow "$what"
	elif [[ "$out" == *"ValidatingAdmissionPolicy '$policy'"*"denied request: "* ]]; then
		msg="${out#*denied request: }"
		report "$want" deny "$what" "policy: ${msg%%$'\n'*}"
	elif [[ "$out" == *"is forbidden: User \"system:serviceaccount:cridge:cridge\" cannot "* ]]; then
		report "$want" deny "$what" RBAC
	else
		warn "$what: failed for another reason: ${out%%$'\n'*}"
		failures=$((failures + 1))
	fi
}

# pod <namespace> <spec-json> [annotations-json]
pod() {
	local annotations="${3:-}"
	printf '{"apiVersion":"v1","kind":"Pod","metadata":{"name":"policy-test","namespace":"%s","annotations":%s},"spec":%s}' \
		"$1" "${annotations:-"{}"}" "$2"
}
expect_pod() {
	local want=$1 what=$2
	shift 2
	pod "$@" | dry_run "$want" "Pod: $what" devstack-order-pods
}

# application <name> <namespace> <project> <destination namespace> <repo> [helm values] [sync option]
application() {
	jq -n --arg name "$1" --arg ns "$2" --arg project "$3" --arg dest "$4" --arg repo "$5" \
		--arg values "${6:-}" --arg option "${7:-}" \
		--arg chart "$ARGOCD_TEST_CHART" --arg version "$ARGOCD_TEST_CHART_VERSION" '{
		apiVersion: "argoproj.io/v1alpha1", kind: "Application",
		metadata: ({name: $name} + if $ns == "" then {} else {namespace: $ns} end),
		spec: {
			project: $project,
			destination: {name: "in-cluster", namespace: $dest},
			source: ({repoURL: $repo, chart: $chart, targetRevision: $version}
				+ if $values == "" then {} else {helm: {values: $values}} end),
			syncPolicy: ({automated: {prune: true, selfHeal: true}}
				+ if $option == "" then {} else {syncOptions: [$option]} end)
		}}'
}

# argocd_says <application> <text>: whether Argo CD reports <text> for the Application in CHECK.
argocd_says() {
	kubectl -n "$CHECK" get application "$1" -o json 2>/dev/null |
		jq -e --arg t "$2" '[.status.conditions[]?.message, .status.operationState.message,
			.status.operationState.syncResult.resources[]?.message] | map(strings) | any(contains($t))' >/dev/null
}
# argocd_refuses <application> <what> <text>
argocd_refuses() {
	if (retry 120 "Argo CD to refuse $2" argocd_says "$1" "$3"); then
		ok "Argo CD: $2: refused ($3)"
	else
		failures=$((failures + 1))
	fi
}
pods_refused() {
	kubectl -n "$CHECK" get replicasets -o json |
		jq -e '[.items[].status.conditions[]?.message] | any(contains("devstack-order-pods"))' >/dev/null
}

for ns in "$CHECK" "$LABELLED"; do
	kubectl create namespace "$ns" --dry-run=client -o yaml | quiet kubectl apply -f -
	quiet kubectl label namespace "$ns" org.etsi.osl=org.etsi.osl --overwrite
done
kubectl create namespace "$DEST" --dry-run=client -o yaml | quiet kubectl apply -f -

info "checking Pods in order namespaces (manifests/argocd-access.yaml), without exceptions"
argocd_access "" ""
C='{"name":"a","image":"alpine"}'
expect_pod allow "plain, in an order namespace" "$CHECK" "{\"containers\":[$C]}"
expect_pod allow "baseline capability" "$CHECK" '{"containers":[{"name":"a","image":"alpine","securityContext":{"capabilities":{"add":["NET_BIND_SERVICE"]}}}]}'
expect_pod deny "privileged" "$CHECK" '{"containers":[{"name":"a","image":"alpine","securityContext":{"privileged":true}}]}'
expect_pod deny "privileged, in a namespace labelled org.etsi.osl" "$LABELLED" '{"containers":[{"name":"a","image":"alpine","securityContext":{"privileged":true}}]}'
expect_pod deny "privileged, in a namespace named like an order" "$DEST" '{"containers":[{"name":"a","image":"alpine","securityContext":{"privileged":true}}]}'
expect_pod deny "privileged init container" "$CHECK" "{\"containers\":[$C],\"initContainers\":[{\"name\":\"i\",\"image\":\"alpine\",\"securityContext\":{\"privileged\":true}}]}"
expect_pod deny "host network" "$CHECK" "{\"hostNetwork\":true,\"containers\":[$C]}"
expect_pod deny "host PID" "$CHECK" "{\"hostPID\":true,\"containers\":[$C]}"
expect_pod deny "host path" "$CHECK" "{\"containers\":[$C],\"volumes\":[{\"name\":\"h\",\"hostPath\":{\"path\":\"/\"}}]}"
expect_pod deny "host port" "$CHECK" '{"containers":[{"name":"a","image":"alpine","ports":[{"containerPort":80,"hostPort":8080}]}]}'
expect_pod deny "capability SYS_ADMIN" "$CHECK" '{"containers":[{"name":"a","image":"alpine","securityContext":{"capabilities":{"add":["SYS_ADMIN"]}}}]}'
expect_pod deny "unconfined seccomp" "$CHECK" "{\"securityContext\":{\"seccompProfile\":{\"type\":\"Unconfined\"}},\"containers\":[$C]}"
expect_pod deny "unconfined AppArmor annotation" "$CHECK" "{\"containers\":[$C]}" '{"container.apparmor.security.beta.kubernetes.io/a":"unconfined"}'
expect_pod deny "SELinux user" "$CHECK" '{"containers":[{"name":"a","image":"alpine","securityContext":{"seLinuxOptions":{"user":"system_u"}}}]}'
expect_pod deny "unsafe sysctl" "$CHECK" "{\"securityContext\":{\"sysctls\":[{\"name\":\"kernel.msgmax\",\"value\":\"1\"}]},\"containers\":[$C]}"
expect_pod allow "privileged, in another namespace" default '{"containers":[{"name":"a","image":"alpine","securityContext":{"privileged":true}}]}'
NET_ADMIN='{"containers":[{"name":"a","image":"alpine","securityContext":{"capabilities":{"add":["NET_ADMIN"]}}}]}'
tun() { printf '{"containers":[%s],"volumes":[{"name":"tun","hostPath":{"path":"%s"%s}}]}' "$C" "$1" "${2:+,\"type\":\"$2\"}"; }
expect_pod deny "capability NET_ADMIN" "$CHECK" "$NET_ADMIN"
expect_pod deny "device /dev/net/tun" "$CHECK" "$(tun /dev/net/tun CharDevice)"

info "checking Pods in order namespaces with the exceptions NET_ADMIN and /dev/net/tun"
argocd_access NET_ADMIN /dev/net/tun
expect_pod allow "capability NET_ADMIN" "$CHECK" "$NET_ADMIN"
expect_pod allow "device /dev/net/tun" "$CHECK" "$(tun /dev/net/tun CharDevice)"
expect_pod deny "/dev/net/tun without type CharDevice" "$CHECK" "$(tun /dev/net/tun)"
expect_pod deny "/dev/net/tun as a directory" "$CHECK" "$(tun /dev/net/tun Directory)"
expect_pod deny "another device" "$CHECK" "$(tun /dev/mem CharDevice)"
expect_pod deny "capability SYS_ADMIN" "$CHECK" '{"containers":[{"name":"a","image":"alpine","securityContext":{"capabilities":{"add":["SYS_ADMIN"]}}}]}'
expect_pod deny "privileged" "$CHECK" '{"containers":[{"name":"a","image":"alpine","securityContext":{"privileged":true}}]}'
if (argocd_access SYS_ADMIN "" 2>/dev/null); then
	warn "ARGOCD_POD_CAPABILITIES=SYS_ADMIN: accepted, expected refused"
	failures=$((failures + 1))
else
	ok "ARGOCD_POD_CAPABILITIES=SYS_ADMIN: refused"
fi
argocd_access

info "checking the Applications CRIDGE may create"
R="$ARGOCD_TEST_REPO"
application policy-test "$CHECK" openslice "$CHECK" "$R" | dry_run allow "CRIDGE: Application in project openslice" devstack-cridge-applications "${AS[@]}"
application policy-test "$CHECK" default "$CHECK" "$R" | dry_run deny "CRIDGE: Application in project default" devstack-cridge-applications "${AS[@]}"
application policy-test "$CHECK" openslice "$CHECK" "$R" "" CreateNamespace=true | dry_run deny "CRIDGE: Application creating its namespace" devstack-cridge-applications "${AS[@]}"
application policy-test "$ARGOCD_NS" openslice "$CHECK" "$R" | dry_run deny "CRIDGE: Application in the argocd namespace" devstack-cridge-resources "${AS[@]}"

info "checking what Argo CD deploys for the project openslice"
argocd_project "$ARGOCD_TEST_REPO"
application check-repo "$CHECK" openslice "$CHECK" https://charts.example.com | quiet kubectl apply -f -
application check-destination "$CHECK" openslice default "$R" | quiet kubectl apply -f -
application check-project "$CHECK" default "$CHECK" "$R" | quiet kubectl apply -f -
application check-ingress "$CHECK" openslice "$CHECK" "$R" $'ingress:\n  enabled: true' | quiet kubectl apply -f -
application check-privileged "$CHECK" openslice "$CHECK" "$R" $'securityContext:\n  privileged: true' | quiet kubectl apply -f -
argocd_refuses check-repo "a repository not in ARGOCD_REPOS" "not permitted in project 'openslice'"
argocd_refuses check-destination "a destination outside the order namespaces" "do not match any of the allowed destinations in project 'openslice'"
argocd_refuses check-project "an order namespace's Application in project default" "is not permitted to use project 'default'"
argocd_refuses check-ingress "a chart with an Ingress" "resource networking.k8s.io:Ingress is not permitted in project openslice"
if (retry 180 "the privileged Pods of check-privileged to be refused" pods_refused); then
	ok "Argo CD: a chart with privileged Pods: its Deployment is created, its Pods are refused (devstack-order-pods)"
else
	failures=$((failures + 1))
fi
((failures == 0)) || die "$failures Argo CD check(s) failed; see scripts/argocd.sh and manifests/argocd-access.yaml"

info "ordering $ARGOCD_TEST_CHART through OpenSlice and Argo CD"
CR="$(application podinfo "" openslice "$DEST" "$ARGOCD_TEST_REPO" |
	jq '.metadata.finalizers = ["resources-finalizer.argocd.argoproj.io"]')"
retry 180 "CRIDGE to publish $RSPEC" rspec_published
rfss="$(osl_cr_rfss "$TAG $ARGOCD_TEST_CHART RFSS" "$RSPEC" "$CR" status.health.status Healthy)"
cfss="$(osl_cfss "$TAG $ARGOCD_TEST_CHART" "$rfss")"
order="$(osl_order "$cfss" "$TAG $ARGOCD_TEST_CHART")"
osl_ack "$order"
ok "service order $order acknowledged"

retry 300 "the Application in namespace $order to be healthy" app_healthy
retry 60 "$ARGOCD_TEST_CHART to run in namespace $DEST" chart_up
ok "CRIDGE created the Application in namespace $order, and Argo CD deployed $ARGOCD_TEST_CHART"
retry 300 "order $order to complete" order_completed
ok "order completed; OpenSlice reports the services active"

info "terminating the services"
osl_terminate "$TAG"
retry 240 "the Application to be deleted" app_gone
retry 120 "$ARGOCD_TEST_CHART to be removed" chart_gone
ok "termination removed the Application and what Argo CD deployed"
passed=true
ok "Argo CD end-to-end test passed ($OSL_URL)"
