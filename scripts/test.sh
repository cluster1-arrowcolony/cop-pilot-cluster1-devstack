#!/usr/bin/env bash
# End-to-end check: Blueprint -> Kolony -> ColonyOS -> docker-reconciler -> executor -> function call.
# Runs in a namespace without its own credentials but with CRIDGE's label, like the per-order
# namespaces OpenSlice creates.
source "$(dirname "$0")/lib.sh"
need kubectl colonies docker

NS=devstack-test
BP=echo-test
# Unique per run, so executors left over from an earlier run (or deployed by hand) don't count.
TYPE="devstack-echo-$(date +%s)"
colonies_cli_env

executor_up() { colonies executor ls --type "$TYPE" 2>/dev/null | grep -q -- "$TYPE"; }
executor_gone() { ! executor_up; }

cleanup() {
	if (($? != 0)); then
		diagnostics "$NS"
	fi
	kubectl delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

# A previous run's namespace may still be terminating.
retry 120 "namespace $NS from an earlier run to be deleted" bash -c "[[ \$(kubectl get namespace $NS -o jsonpath='{.status.phase}' 2>/dev/null) != Terminating ]]"
info "applying Blueprint $NS/$BP (no credentials Secret in that namespace)"
kubectl create namespace "$NS" --dry-run=client -o yaml | quiet kubectl apply -f -
quiet kubectl label namespace "$NS" org.etsi.osl=org.etsi.osl --overwrite
kubectl apply -f - >/dev/null <<YAML
apiVersion: colony.colonyos.io/v1
kind: Blueprint
metadata:
  name: $BP
  namespace: $NS
spec:
  kind: ExecutorDeployment
  locationName: $LOCATION_NAME
  data:
    executorType: $TYPE
    image: $ECHO_EXECUTOR_IMAGE
    replicas: 1
YAML

retry 90 "Blueprint to sync" bash -c "[[ \$(kubectl -n $NS get blueprint $BP -o jsonpath='{.status.synced}') == true ]]"
ok "Blueprint synced to ColonyOS"

retry 180 "echo executor to start and register" executor_up
ok "reconciler started an echo executor"

out="$(colonies function exec --func echo --args devstack-ok --targettype "$TYPE" --wait --out 2>/dev/null || true)"
[[ "$out" == *devstack-ok* ]] || die "function call through the echo executor failed: $out"
ok "function call answered: $(echo "$out" | tr -d '\n')"

info "submitting a ColonyProcess"
kubectl apply -f - >/dev/null <<YAML
apiVersion: colony.colonyos.io/v1
kind: ColonyProcess
metadata:
  name: echo-process
  namespace: $NS
spec:
  funcName: echo
  executorType: $TYPE
  args: ["process-ok"]
  maxExecTime: 60
YAML
retry 90 "ColonyProcess to succeed" bash -c "[[ \$(kubectl -n $NS get colonyprocess echo-process -o jsonpath='{.status.state}') == Success ]]"
ok "ColonyProcess finished: $(kubectl -n $NS get colonyprocess echo-process -o jsonpath='{.status.output}')"

info "deleting the namespace"
kubectl delete namespace "$NS" --timeout=90s >/dev/null
retry 120 "echo executor to be removed" executor_gone
ok "namespace deleted, Blueprint removed from ColonyOS and executor gone"
trap - EXIT
ok "end-to-end test passed"
