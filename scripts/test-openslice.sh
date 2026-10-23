#!/usr/bin/env bash
# End-to-end check through OpenSlice: service order -> OSOM -> CRIDGE -> Blueprint CR in the
# order's namespace -> Kolony -> ColonyOS -> executor, status back to OpenSlice, then termination.
# Uses OSL_URL/OSL_USER/OSL_PASSWORD, which openslice-local.sh and openslice-ice.sh provide.
source "$(dirname "$0")/lib.sh"
source "$ROOT/scripts/osl.sh"
need kubectl colonies jq curl

: "${OSL_URL:?}" "${OSL_USER:?}" "${OSL_PASSWORD:?}"
colonies_cli_env
osl_login

# How CRIDGE names this cluster: <cluster>@<API URL> from the kubeconfig it was given.
RSPEC="Blueprint@colony.colonyos.io/v1@k3d-$CLUSTER_NAME@https://$COLONIES_NODE_HOST:6443/"
TAG="devstack-$CLUSTER_NAME-$(date +%s)"
# Unique per run, so executors left over from an earlier run (or deployed by hand) don't count.
TYPE="$TAG-echo"

CR="$(cat <<YAML
apiVersion: colony.colonyos.io/v1
kind: Blueprint
metadata:
  name: echo
spec:
  kind: ExecutorDeployment
  locationName: $LOCATION_NAME
  data:
    executorType: $TYPE
    image: $ECHO_EXECUTOR_IMAGE
    replicas: 1
YAML
)"

rfss="" cfss="" order="" passed=false

cr_synced() { [[ "$(kubectl -n "$order" get blueprints -o jsonpath='{.items[*].status.synced}')" == true ]]; }
cr_gone() { [[ -z "$(kubectl -n "$order" get blueprints -o name 2>/dev/null)" ]]; }
executor_up() { colonies executor ls --type "$TYPE" 2>/dev/null | grep -q -- "$TYPE"; }
executor_gone() { ! executor_up; }
order_completed() { [[ "$(osl GET "/serviceOrdering/v4/serviceOrder/$order" | jq -r .state)" == COMPLETED ]]; }

# cridge_logs: the end of the log of the CRIDGE that serves this cluster.
cridge_logs() {
	local where
	case "$OPENSLICE" in
	local) where="-n openslice deploy/openslice-cridge" ;;
	*) where="-n openslice-bridge deploy/cridge" ;;
	esac
	echo "--- kubectl logs $where --tail 20" >&2
	# shellcheck disable=SC2086 # $where is namespace flag plus resource
	kubectl logs $where --tail 20 2>&1 | mask_secrets >&2 || true
}

# Runs on success and on failure, so that a test against the shared ICE catalog leaves no specs,
# services or CRs behind. Best effort: it reports what it could not remove, and the test's own
# exit status is kept.
cleanup() {
	local spec
	set +e
	if [[ "$passed" != true && -n "$order" ]]; then
		diagnostics "$order"
		cridge_logs
		osl_terminate "$TAG" >/dev/null 2>&1 || warn "could not terminate the services of order $order in $OSL_URL"
		for _ in $(seq 30); do cr_gone && break; sleep 2; done
		kubectl delete namespace "$order" --ignore-not-found --wait=false >/dev/null 2>&1
	fi
	for spec in $cfss $rfss; do
		osl DELETE "/serviceCatalogManagement/v4/serviceSpecification/$spec" >/dev/null 2>&1 ||
			warn "could not delete service specification $spec from $OSL_URL; remove it by hand"
	done
}
trap cleanup EXIT

info "creating service specs for $RSPEC"
rfss="$(osl_cr_rfss "$TAG echo RFSS" "$RSPEC" "$CR" status.synced true)"
cfss="$(osl_cfss "$TAG echo" "$rfss")"

order="$(osl_order "$cfss" "$TAG echo")"
osl_ack "$order"
ok "service order $order acknowledged"

retry 180 "the Blueprint CR in namespace $order" cr_synced
ok "CRIDGE created the Blueprint in namespace $order and Kolony synced it"
retry 180 "an echo executor" executor_up
ok "reconciler started the executor"
retry 300 "order $order to complete" order_completed
ok "order completed; OpenSlice reports the services active"

info "terminating the services"
osl_terminate "$TAG"
retry 240 "the Blueprint CR to be deleted" cr_gone
retry 120 "the echo executor to stop" executor_gone
ok "termination removed the CR, the ColonyOS Blueprint and the executor"
passed=true
ok "OpenSlice end-to-end test passed ($OSL_URL)"
