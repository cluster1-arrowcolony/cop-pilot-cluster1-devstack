#!/usr/bin/env bash
# Test of the scaling-policy catalogue entry (catalog/scaling-policy): a bundle whose "replicas"
# characteristic reaches the part's Blueprint through LCM rules, at creation and on changes to
# the running service. It checks the OpenSlice 2025Q4 behaviour on day-2 changes:
#   A  a PATCH of the bundle's characteristic in the service inventory (what the portal does)
#      scales the executors: the SUPERVISION rule rewrites the part's _CR_SPEC, CRIDGE patches the CR
#   B  a "modify" service order carrying the bundle's own characteristic changes nothing: OSOM's
#      modify delegate only copies "<part name>::<characteristic>" into the parts
#   C  a "modify" order carrying "<part>::_CR_SPEC" changes nothing while the SUPERVISION rule
#      owns _CR_SPEC: the rule rewrites it before the patch task runs
#   D  the same order scales the executors once the SUPERVISION rule is deleted
# Any other outcome is a failure (a later OpenSlice release may change B and C: then update
# catalog/README.md as well). Takes about ten minutes.
# Uses OSL_URL/OSL_USER/OSL_PASSWORD (for OPENSLICE=local: OSL_URL=$OPENSLICE_URL, OSL_USER=devstack,
# OSL_PASSWORD=$OPENSLICE_PASSWORD from .devstack/identities.env). KEEP=1 leaves specs, rules and services for inspection.
source "$(dirname "$0")/lib.sh"
source "$ROOT/scripts/osl.sh"
need kubectl colonies jq curl

: "${OSL_URL:?}" "${OSL_USER:?}" "${OSL_PASSWORD:?}"
colonies_cli_env
osl_login

CAT="$ROOT/catalog/scaling-policy"
RSPEC="Blueprint@colony.colonyos.io/v1@k3d-$CLUSTER_NAME@https://$COLONIES_NODE_HOST:6443/"
TAG="scaling-$CLUSTER_NAME-$(date +%s)"
TYPE="$TAG-echo"
RFSNAME="$TAG echo executors"
CFSSNAME="$TAG scaling policy"

fill() { sed -e "s|@LOCATION@|$LOCATION_NAME|g" -e "s|@TYPE@|$TYPE|g" -e "s|@IMAGE@|$ECHO_EXECUTOR_IMAGE|g" -e "s|@RFSNAME@|$RFSNAME|g" "$1"; }
CR="$(fill "$CAT/echo.cr.yaml")"
fill "$CAT/cr-spec-from-replicas.rule.java" >"$STATE/scaling-policy-rule.java"

rfss="" cfss="" order="" cfs_service="" rfs_service=""; rules=(); results=(); failures=0
executors() { colonies executor ls --type "$TYPE" 2>/dev/null | grep -c -- "$TYPE" || true; }
executors_are() { [[ "$(executors)" == "$1" ]]; }
cr_synced() { [[ "$(kubectl -n "$order" get blueprints -o jsonpath='{.items[*].status.synced}')" == true ]]; }
cr_gone() { [[ -z "$(kubectl -n "$order" get blueprints -o name 2>/dev/null)" ]]; }
cr_replicas() { kubectl -n "$order" get blueprints -o jsonpath='{.items[0].spec.data.replicas}' 2>/dev/null; }
part_replicas() { osl_service_char "$rfs_service" _CR_SPEC | grep -o 'replicas: [0-9]*' | cut -d' ' -f2; }
order_state() { osl GET "/serviceOrdering/v4/serviceOrder/$1" | jq -r .state; }
order_completed() { [[ "$(order_state "$1")" == COMPLETED ]]; }
stamp() { date +%H:%M:%S; }
passed() { results+=("$1"); ok "$1"; }
failed() {
	results+=("$1"); failures=$((failures + 1)); warn "$1"
	echo "   --- bundle service notes" >&2; osl_service_notes "$cfs_service" 6 | sed 's/^/   /' >&2
	echo "   --- CR replicas=$(cr_replicas), part _CR_SPEC replicas=$(part_replicas), executors=$(executors)" >&2
}
# retry_quiet: like retry, but returns 1 on timeout instead of dying.
retry_quiet() {
	local timeout=$1; shift
	local deadline=$((SECONDS + timeout))
	until "$@" >/dev/null 2>&1; do ((SECONDS >= deadline)) && return 1; sleep 3; done
}
# expect_scale <n> <seconds> <label>: the CR and the executors must reach n within the time.
expect_scale() {
	local n=$1 secs=$2 label=$3 t0=$SECONDS
	if retry_quiet "$secs" executors_are "$n" && [[ "$(cr_replicas)" == "$n" ]]; then
		passed "$label: $n executors after $((SECONDS - t0))s"
	else
		failed "$label: expected $n executors within ${secs}s"
	fi
}
# expect_unchanged <n> <seconds> <order> <label>: the order completes, and the CR, the part's
# _CR_SPEC and the executors stay at n for the whole time.
expect_unchanged() {
	local n=$1 secs=$2 o=$3 label=$4 deadline=$((SECONDS + $2)) seen
	until ((SECONDS >= deadline)); do
		seen="$(cr_replicas)/$(part_replicas)/$(executors)"
		[[ "$seen" == "$n/$n/$n" ]] || { failed "$label: expected no change, saw CR/part/executors $seen"; return; }
		sleep 5
	done
	if order_completed "$o"; then
		passed "$label: no change in ${secs}s, order COMPLETED"
	else
		failed "$label: no change, but the order is $(order_state "$o") instead of COMPLETED"
	fi
}

cleanup() {
	set +e
	echo >&2; printf '   %s\n' "${results[@]}" >&2
	[[ "${KEEP:-}" == 1 ]] && { warn "KEEP=1: leaving order $order, specs and rules in place"; return; }
	if [[ -n "$order" ]]; then
		osl_terminate "$TAG" >/dev/null 2>&1 || warn "could not terminate the services of $TAG"
		for _ in $(seq 40); do cr_gone && break; sleep 3; done
		kubectl delete namespace "$order" --ignore-not-found --wait=false >/dev/null 2>&1
	fi
	local r; for r in "${rules[@]}"; do osl DELETE "/lcmrulesmanagement/v1/lcmRuleSpecification/$r" >/dev/null 2>&1 || warn "rule $r not deleted"; done
	local spec; for spec in $cfss $rfss; do osl DELETE "/serviceCatalogManagement/v4/serviceSpecification/$spec" >/dev/null 2>&1 || warn "spec $spec not deleted"; done
}
trap cleanup EXIT

info "scaling policy $(stamp): RFS '$RFSNAME', bundle '$CFSSNAME' on $RSPEC"
rfss="$(osl_cr_rfss "$RFSNAME" "$RSPEC" "$CR" status.synced true)"
cfss="$(osl_cfss_chars "$CFSSNAME" "$rfss" '[{"name":"replicas","value":"1"},{"name":"maxReplicas","value":"3"}]')"
rules+=("$(osl_rule "$TAG cr-spec pre-provision" PRE_PROVISION "$cfss" "$STATE/scaling-policy-rule.java")")
rules+=("$(osl_rule "$TAG cr-spec supervision" SUPERVISION "$cfss" "$STATE/scaling-policy-rule.java")")
ok "specs $rfss, $cfss and rules ${rules[*]} created"

# --- Creation with replicas=1 through the PRE_PROVISION rule
t0=$SECONDS
order="$(jq -n --arg id "$cfss" --arg name "$CFSSNAME" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{
	description: "scaling policy test order", requestedStartDate: $now,
	orderItem: [{id: "1", action: "add", service: {name: $name, serviceSpecification: {id: $id, name: $name},
		serviceCharacteristic: [{name: "replicas", value: {value: "1", alias: ""}, valueType: "TEXT"},
		                        {name: "maxReplicas", value: {value: "3", alias: ""}, valueType: "TEXT"}]}}]}' |
	{ osl POST "/serviceOrdering/v4/serviceOrder" "$(cat)"; } | jq -er .id)"
osl_ack "$order"; ok "order $order acknowledged $(stamp)"
retry 180 "the Blueprint CR in namespace $order" cr_synced
retry 180 "one echo executor" executors_are 1
retry 300 "order $order to complete" order_completed "$order"
cfs_service="$(osl GET "/serviceInventory/v4/service?serviceOrder.id=$order" 2>/dev/null | jq -r '[.[] | select(.category=="CustomerFacingService")][0].id // empty')"
[[ -n "$cfs_service" ]] || cfs_service="$(osl GET "/serviceOrdering/v4/serviceOrder/$order" | jq -r '.orderItem[0].service.id')"
rfs_service="$(osl_service "$cfs_service" | jq -r '.supportingService[0].id')"
if [[ "$(cr_replicas)" == 1 ]]; then
	passed "creation: PRE_PROVISION rule set replicas=1, order COMPLETED after $((SECONDS - t0))s"
else
	failed "creation: PRE_PROVISION rule did not set replicas=1"
fi

# --- A: PATCH the bundle's own characteristic (portal style)
info "A $(stamp): PATCH bundle service replicas=3"
osl_patch_service_char "$cfs_service" replicas 3
expect_scale 3 180 "A: inventory PATCH replicas=3"

# --- B: modify order carrying the bundle's own characteristic
info "B $(stamp): modify order with replicas=2 on the bundle"
mo="$(osl_order_modify "$cfs_service" '[{"name":"replicas","value":"2"}]')"
expect_unchanged 3 150 "$mo" "B: modify order replicas=2 on the bundle"

# --- C: modify order carrying the part's _CR_SPEC while the SUPERVISION rule owns it
info "C $(stamp): modify order with '$RFSNAME::_CR_SPEC' replicas=1, SUPERVISION rule active"
crspec="$(osl_service_char "$rfs_service" _CR_SPEC | sed 's/replicas: [0-9]*/replicas: 1/')"
mo="$(osl_order_modify "$cfs_service" "$(jq -n --arg n "$RFSNAME::_CR_SPEC" --arg v "$crspec" '[{name: $n, value: $v}]')")"
expect_unchanged 3 150 "$mo" "C: modify order <part>::_CR_SPEC replicas=1 with the rule active"

# --- D: the same without the SUPERVISION rule
info "D $(stamp): delete the SUPERVISION rule, then modify order with '$RFSNAME::_CR_SPEC' replicas=2"
osl DELETE "/lcmrulesmanagement/v1/lcmRuleSpecification/${rules[1]}" >/dev/null && unset 'rules[1]'
crspec="$(osl_service_char "$rfs_service" _CR_SPEC | sed 's/replicas: [0-9]*/replicas: 2/')"
mo="$(osl_order_modify "$cfs_service" "$(jq -n --arg n "$RFSNAME::_CR_SPEC" --arg v "$crspec" '[{name: $n, value: $v}]')")"
expect_scale 2 180 "D: modify order <part>::_CR_SPEC replicas=2 without the rule"
sleep 60
if [[ "$(cr_replicas)/$(executors)" == 2/2 ]]; then passed "D: still 2 executors 60 s later"; else failed "D: changed again after the order: CR replicas=$(cr_replicas), executors=$(executors)"; fi

info "termination $(stamp)"
osl_terminate "$TAG"
retry 240 "the Blueprint CR to be deleted" cr_gone
retry 120 "the executors to be gone" executors_are 0
passed "termination: CR, Blueprint and executors removed"

if ((failures > 0)); then die "scaling policy test: $failures unexpected result(s)"; fi
ok "scaling policy test passed ($TAG)"
