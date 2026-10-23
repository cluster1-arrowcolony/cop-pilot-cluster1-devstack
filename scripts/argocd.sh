# Argo CD for OpenSlice orders (ARGOCD=on, OPENSLICE=local). Source after lib.sh.
# shellcheck shell=bash
#
# OpenSlice deploys Helm charts as Argo CD Applications (the DO guide's way), which CRIDGE creates
# in order namespaces. Argo CD installs a chart with its own rights, which reach the whole cluster,
# so it is set up to keep orders to order namespaces:
#
# - Argo CD takes Applications only from namespaces named like an order ID, and only in the
#   project "openslice" (argocd_project below), which allows the repositories in ARGOCD_REPOS,
#   destinations in order namespaces, no cluster-scoped resources, and none of the namespaced
#   kinds that would reach further: RBAC, Ingresses, Kolony's and Argo CD's own kinds.
# - manifests/argocd-access.yaml holds CRIDGE to that project and its Applications to existing
#   namespaces, and Pods in order namespaces to the Pod Security Standards' baseline, with the
#   exceptions in ARGOCD_POD_CAPABILITIES and ARGOCD_POD_DEVICES (argocd_access below).

ARGOCD_NS=argocd
# CRIDGE names an order's namespace after the order's ID. Argo CD takes regular expressions,
# between slashes, for the namespaces Applications may live in, but only globs for destinations.
ORDER_NS_REGEX='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
# The glob library takes one range per character class, so the class lists the hex digits; a
# pattern it cannot compile matches nothing.
_hex() { printf '[0123456789abcdef]%.0s' $(seq "$1"); }
ORDER_NS_GLOB="$(_hex 8)-$(_hex 4)-$(_hex 4)-$(_hex 4)-$(_hex 12)"
unset -f _hex

# argocd_project [repo...]: write the AppProject "openslice", whose Applications may deploy the
# charts of ARGOCD_REPOS and of the repositories given (make test adds its own for the test).
# shellcheck disable=SC2120 # only test-argocd.sh passes repositories
argocd_project() {
	# shellcheck disable=SC2086 # ARGOCD_REPOS is a space-separated list
	jq -n --arg glob "$ORDER_NS_GLOB" --arg regex "/$ORDER_NS_REGEX/" --arg ns "$ARGOCD_NS" \
		--args '{
		apiVersion: "argoproj.io/v1alpha1", kind: "AppProject",
		metadata: {name: "openslice", namespace: $ns},
		spec: {
			description: "OpenSlice orders (cop-pilot-cluster1-devstack, scripts/argocd.sh)",
			sourceNamespaces: [$regex],
			sourceRepos: $ARGS.positional,
			destinations: [{server: "https://kubernetes.default.svc", name: "in-cluster", namespace: $glob}],
			clusterResourceWhitelist: [],
			namespaceResourceBlacklist: [
				{group: "rbac.authorization.k8s.io", kind: "*"},
				{group: "networking.k8s.io", kind: "Ingress"},
				{group: "colony.colonyos.io", kind: "*"},
				{group: "argoproj.io", kind: "*"}
			]
		}}' $ARGOCD_REPOS "$@" | quiet kubectl apply -f -
}

# Capabilities that give a container the host, or much of it, whatever else it is denied.
HOST_CAPABILITIES="ALL SYS_ADMIN SYS_MODULE SYS_RAWIO SYS_PTRACE SYS_BOOT DAC_READ_SEARCH BPF PERFMON"

# argocd_access [capabilities] [devices]: apply manifests/argocd-access.yaml, with these
# exceptions to the Pod policy (space-separated), ARGOCD_POD_CAPABILITIES and ARGOCD_POD_DEVICES
# unless given (make test passes its own for the test).
argocd_access() {
	local caps="${1-$ARGOCD_POD_CAPABILITIES}" devices="${2-$ARGOCD_POD_DEVICES}" c d
	for c in $caps; do
		[[ "$c" =~ ^[A-Z_]+$ && "$c" != CAP_* ]] ||
			die "ARGOCD_POD_CAPABILITIES lists capabilities as Kubernetes names them, e.g. NET_ADMIN (got '$c')"
		[[ " $HOST_CAPABILITIES " != *" $c "* ]] ||
			die "ARGOCD_POD_CAPABILITIES may not give Pods $c, which reaches the host"
	done
	for d in $devices; do
		[[ "$d" =~ ^/dev/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$ && "$d" != *..* ]] ||
			die "ARGOCD_POD_DEVICES lists character devices under /dev, e.g. /dev/net/tun (got '$d')"
	done
	# shellcheck disable=SC2086 # space-separated lists
	kubectl create --dry-run=client -o json -f "$ROOT/manifests/argocd-access.yaml" |
		jq -s --argjson caps "$(jq -nc '$ARGS.positional' --args $caps)" \
			--argjson devices "$(jq -nc '$ARGS.positional' --args $devices)" '{
			apiVersion: "v1", kind: "List",
			items: map(if .metadata.name == "devstack-order-pods" and .kind == "ValidatingAdmissionPolicy"
				then .spec.variables |= map(
					if .name == "capabilities" then .expression = ($caps | tojson)
					elif .name == "devices" then .expression = ($devices | tojson)
					else . end)
				else . end)}' |
		quiet kubectl apply -f -
}

argocd_up() {
	local values="$STATE/argocd-values.yaml"
	argocd_access
	cat >"$values" <<-YAML
		global:
		  image:
		    tag: "$ARGOCD_IMAGE_TAG"
		configs:
		  params:
		    application.namespaces: "/$ORDER_NS_REGEX/"
		dex:
		  enabled: false
		notifications:
		  enabled: false
		applicationSet:
		  replicas: 0
		redis:
		  image:
		    # The chart's default registry has no cache (scripts/cache.sh); this is the same image.
		    repository: docker.io/library/redis
	YAML
	info "installing Argo CD $ARGOCD_IMAGE_TAG (chart $ARGOCD_CHART_VERSION)"
	quiet helm upgrade --install argocd argo-cd \
		--repo https://argoproj.github.io/argo-helm --version "$ARGOCD_CHART_VERSION" \
		--namespace "$ARGOCD_NS" --create-namespace --values "$values" --wait --timeout 10m
	argocd_project
	if [[ -z "${ARGOCD_REPOS// /}" ]]; then
		warn "ARGOCD_REPOS is empty, so orders cannot deploy any chart through Argo CD"
	fi
	ok "Argo CD deploys OpenSlice orders' Applications from ${ARGOCD_REPOS:-no repository} into order namespaces"
	if [[ -n "${ARGOCD_POD_CAPABILITIES// /}${ARGOCD_POD_DEVICES// /}" ]]; then
		info "Pods in order namespaces may also use ${ARGOCD_POD_CAPABILITIES:-no other capabilities} and ${ARGOCD_POD_DEVICES:-no host devices}"
	fi
}

# argocd_down: remove Argo CD and its policies, unless Applications are left, which need Argo CD
# to remove what they deployed.
argocd_down() {
	local apps
	helm status argocd -n "$ARGOCD_NS" >/dev/null 2>&1 || return 0
	apps="$(kubectl get applications.argoproj.io -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
	if ((apps > 0)); then
		warn "ARGOCD=off, but Argo CD still has $apps Application(s); terminate their services in OpenSlice, then run 'make openslice' again"
		return
	fi
	kubectl -n "$ARGOCD_NS" delete appproject openslice --ignore-not-found >/dev/null
	quiet helm uninstall argocd -n "$ARGOCD_NS" --wait
	quiet kubectl delete --ignore-not-found -f "$ROOT/manifests/argocd-access.yaml"
	ok "Argo CD removed"
}
