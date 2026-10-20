#!/usr/bin/env bash
# Check what CRIDGE's identity may do (manifests/cridge-access.yaml), by impersonating it.
# Writes are server-side dry runs, so nothing is created or deleted.
source "$(dirname "$0")/lib.sh"
need kubectl openssl

AS=(--as=system:serviceaccount:cridge:cridge)
# CRIDGE names each order namespace after the order's ID, and apiserver/authorization.yaml lets it
# read Secrets, Services and ConfigMaps only in namespaces named like that.
NS="$(openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')"
failures=0

cleanup() { kubectl delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT
kubectl create namespace "$NS" --dry-run=client -o yaml | quiet kubectl apply -f -
quiet kubectl label namespace "$NS" org.etsi.osl=org.etsi.osl --overwrite

# denial <kubectl output>: print who refused CRIDGE's request: RBAC, one of the policies in
# manifests/cridge-access.yaml, or the deny rule in apiserver/authorization.yaml. Fails for any
# other error, which must not pass as a refusal.
denial() {
	# The deny rule's webhook endpoint, which the API server names in its error.
	if [[ "$1" == *'https://127.0.0.1:1/'* ]]; then
		echo "authorization config"
	elif [[ "$1" == *"ValidatingAdmissionPolicy 'devstack-cridge-"*"denied request: "* ]]; then
		local msg="${1#*denied request: }"
		echo "policy: ${msg%%$'\n'*}"
	elif [[ "$1" == *'is forbidden: User "system:serviceaccount:cridge:cridge" cannot '* ]]; then
		echo RBAC
	else
		return 1
	fi
}

# expect <allow|deny> <what> <kubectl args...>
expect() {
	local want=$1 what=$2 out got why="" dry=(--dry-run=server)
	shift 2
	what="CRIDGE: $what"
	[[ "$1" != get ]] || dry=()
	if out="$(kubectl "${AS[@]}" "$@" ${dry[@]+"${dry[@]}"} 2>&1)"; then
		got=allow
	elif why="$(denial "$out")"; then
		got=deny
	else
		warn "$what: failed for another reason: ${out%%$'\n'*}"
		failures=$((failures + 1))
		return
	fi
	if [[ "$got" == "$want" ]]; then
		ok "$what: ${got/deny/refus}ed${why:+ ($why)}"
	else
		warn "$what: ${got/deny/refus}ed${why:+ ($why)}, expected ${want/deny/refus}ed"
		failures=$((failures + 1))
	fi
}

# blueprint <namespace> <kind> <data-json>: a Blueprint as JSON on stdin for kubectl create -f -.
blueprint() {
	printf '{"apiVersion":"colony.colonyos.io/v1","kind":"Blueprint","metadata":{"name":"policy-test","namespace":"%s"},"spec":{"kind":"%s","locationName":"%s","data":%s}}' \
		"$1" "$2" "$LOCATION_NAME" "$3"
}
expect_blueprint() {
	local want=$1 what=$2
	shift 2
	expect "$want" "$what" create -f <(blueprint "$@")
}

E='"executorType":"policy-test","image":"alpine","replicas":1'
expect_blueprint allow "Blueprint in an order namespace" "$NS" ExecutorDeployment "{$E}"
expect_blueprint deny "Blueprint in another namespace" default ExecutorDeployment "{$E}"
expect_blueprint deny "privileged ExecutorDeployment" "$NS" ExecutorDeployment "{$E,\"Privileged\":true}"
expect_blueprint deny "ExecutorDeployment host mount" "$NS" ExecutorDeployment "{$E,\"volumes\":[{\"host\":\"/\",\"container\":\"/h\"}]}"
expect_blueprint deny "ExecutorDeployment host mount, Unicode-folded key" "$NS" ExecutorDeployment "{$E,\"volumeſ\":[{\"host\":\"/\",\"container\":\"/h\"}]}"
expect_blueprint deny "ExecutorDeployment host port" "$NS" ExecutorDeployment "{$E,\"ports\":[{\"port\":22}]}"
expect_blueprint deny "privileged DockerDeployment" "$NS" DockerDeployment '{"instances":[{"name":"a","image":"alpine","privileged":true}]}'
expect_blueprint deny "DockerDeployment bind mount" "$NS" DockerDeployment '{"instances":[{"name":"a","image":"alpine","volumes":[{"type":"bind","mountPath":"/h"}]}]}'
# Every field the policy accepts, with harmless values.
D='"name":"a","type":"app","image":"alpine","command":["sleep"],"args":["60"],"environment":{"A":"1"},"dependsOn":["b"],"restartPolicy":"unless-stopped","healthcheck":{"test":"true","interval":"5s","timeout":"1s","retries":3,"startPeriod":"1s"},"resources":{"cpus":"1","memory":"64m"},"labels":{"app":"a"},"privileged":false,"user":"1000","workingDir":"/","hostname":"a","ports":[{"container":80,"protocol":"tcp"}],"volumes":[{"type":"named","name":"data","mountPath":"/d","readOnly":true},{"type":"tmpfs","mountPath":"/t"}]'
expect_blueprint allow "DockerDeployment using every accepted field" "$NS" DockerDeployment "{\"replicas\":1,\"instances\":[{$D}]}"
expect_blueprint allow "ExecutorDeployment using every accepted field" "$NS" ExecutorDeployment "{$E,\"executorName\":\"r\",\"cpu\":\"1\",\"memory\":\"64m\",\"env\":{\"A\":\"1\"},\"command\":[\"x\"],\"args\":[\"y\"],\"entrypoint\":[\"z\"],\"privileged\":false,\"volumes\":[],\"ports\":[]}"
expect_blueprint deny "Blueprint of another kind" "$NS" Other "{$E}"
expect_blueprint deny "ExecutorDeployment unknown field" "$NS" ExecutorDeployment "{$E,\"capAdd\":[\"SYS_ADMIN\"]}"
expect_blueprint deny "DockerDeployment unknown field" "$NS" DockerDeployment '{"instances":[{"name":"a","image":"alpine","pidMode":"host"}]}'
expect_blueprint deny "DockerDeployment envFile" "$NS" DockerDeployment '{"instances":[{"name":"a","image":"alpine","envFile":"/proc/self/environ"}]}'
expect_blueprint deny "DockerDeployment network" "$NS" DockerDeployment '{"network":{"name":"host"},"instances":[{"name":"a","image":"alpine"}]}'
expect_blueprint deny "DockerDeployment volume with a host path field" "$NS" DockerDeployment '{"instances":[{"name":"a","image":"alpine","volumes":[{"type":"named","name":"data","hostPath":"/","mountPath":"/h"}]}]}'
expect_blueprint deny "DockerDeployment volume of an unknown type" "$NS" DockerDeployment '{"instances":[{"name":"a","image":"alpine","volumes":[{"type":"volume","name":"data","mountPath":"/h"}]}]}'
expect_blueprint deny "DockerDeployment colonies.* label" "$NS" DockerDeployment '{"instances":[{"name":"a","image":"alpine","labels":{"colonies.deployment":"other"}}]}'
expect_blueprint deny "DockerDeployment named volume with a host path" "$NS" DockerDeployment '{"instances":[{"name":"a","image":"alpine","volumes":[{"type":"named","name":"/","mountPath":"/h"}]}]}'
expect_blueprint deny "DockerDeployment named volume with a host path, upper-case key" "$NS" DockerDeployment '{"instances":[{"name":"a","image":"alpine","volumes":[{"type":"named","Name":"/var/run/docker.sock","mountPath":"/s"}]}]}'
expect_blueprint deny "DockerDeployment host port" "$NS" DockerDeployment '{"instances":[{"name":"a","image":"alpine","ports":[{"container":80,"host":8080}]}]}'
expect deny "Pod" run policy-test -n "$NS" --image=alpine --restart=Never
expect deny "BlueprintDefinition" create -n "$NS" -f <(printf '{"apiVersion":"colony.colonyos.io/v1","kind":"BlueprintDefinition","metadata":{"name":"policy-test"},"spec":{"kind":"PolicyTest","handler":{"executorType":"x","functionName":"reconcile"}}}')
expect deny "deleting the kolony namespace" delete namespace kolony
expect deny "deleting Secrets in kolony" delete secrets --all -n kolony
expect allow "reading Secrets in an order namespace" get secrets -n "$NS"
expect allow "reading Services in an order namespace" get services -n "$NS"
expect allow "reading ConfigMaps in an order namespace" get configmaps -n "$NS"
expect deny "reading Secrets in kolony" get secrets -n kolony
expect deny "reading Secrets in all namespaces" get secrets -A
expect deny "reading Services in colonyos" get services -n colonyos
expect deny "reading ConfigMaps in kube-system" get configmaps -n kube-system
expect allow "deleting an order namespace" delete namespace "$NS"

((failures == 0)) || die "$failures CRIDGE access check(s) failed; see manifests/cridge-access.yaml and apiserver/authorization.yaml (a cluster created before that file needs 'make down' and 'make up')"
ok "CRIDGE is limited to Kolony resources in its own namespaces"
