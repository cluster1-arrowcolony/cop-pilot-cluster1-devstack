#!/usr/bin/env bash
# Test of the scale-on-queue rule of the scaling-policy catalogue entry (catalog/scaling-policy):
# the scaling loop inside a domain, closed by OpenSlice LCM rules alone. The bundle is ordered with
# replicas=1, maxReplicas=3 and a demand characteristic, queueWaiting, that a reporter program
# writes into the service inventory from the colony's waiting processes (a USER account suffices).
# Demand is QUEUE_N processes submitted for a sibling executor type that nobody serves, so they
# wait for exactly QUEUE_TTL seconds and then expire. The test passes when:
#   1  the order completes with one executor and the part reports its running instances
#   2  within 240 s of the demand, two executors run and the Blueprint says replicas=2
#   3  within another 240 s, three (the cap)
#   4  once the queue has expired, one executor again within 360 s
#   5  at no sample is replicas above maxReplicas, or more than one step ahead of the running
#      instances the part reports (the rule must wait for each step to land)
# Measured on the devstack: two executors 45–60 s after the demand, three after about 160 s, one
# again 40–80 s after the demand is gone. Takes about nine minutes.
# Logs in like test-scaling-policy.sh (the devstack user, or OSL_URL/OSL_USER/OSL_PASSWORD). The reporter logs in as
# REPORTER_USER/REPORTER_PASSWORD if set; otherwise, with OPENSLICE=local, as the user "reporter"
# that scripts/osl-user.sh creates with the role USER; otherwise as the test's own user.
# QUEUE_N (30, below 100), QUEUE_TTL (300) and SCALE_UP_QUEUE (10) can be set. KEEP=1 leaves everything in place.
source "$(dirname "$0")/lib.sh"
source "$ROOT/scripts/osl.sh"
need kubectl colonies jq curl

if [[ "$OPENSLICE" == local ]]; then
	load_identities; : "${OSL_URL:=$OPENSLICE_URL}" "${OSL_USER:=devstack}" "${OSL_PASSWORD:=$OPENSLICE_PASSWORD}"
fi
: "${OSL_URL:?}" "${OSL_USER:?}" "${OSL_PASSWORD:?}"
QUEUE_N=${QUEUE_N:-30}; QUEUE_TTL=${QUEUE_TTL:-300}; SCALE_UP_QUEUE=${SCALE_UP_QUEUE:-10}; MAX_REPLICAS=3
colonies_cli_env
osl_login

CAT="$ROOT/catalog/scaling-policy"
RSPEC="Blueprint@colony.colonyos.io/v1@k3d-$CLUSTER_NAME@https://$COLONIES_NODE_HOST:6443/"
TAG="queue-$CLUSTER_NAME-$(date +%s)"
TYPE="$TAG-echo"
RFSNAME="$TAG echo executors"
CFSSNAME="$TAG scaling policy"

fill() { sed -e "s|@LOCATION@|$LOCATION_NAME|g" -e "s|@TYPE@|$TYPE|g" -e "s|@IMAGE@|$ECHO_EXECUTOR_IMAGE|g" -e "s|@RFSNAME@|$RFSNAME|g" "$1"; }
CR="$(fill "$CAT/echo.cr.yaml")"
fill "$CAT/cr-spec-from-replicas.rule.java" >"$STATE/scale-on-queue-crspec.java"
fill "$CAT/scale-on-queue.rule.java" >"$STATE/scale-on-queue-scale.java"

rfss="" cfss="" order="" cfs_service="" rfs_service="" reporter_pid=""; rules=(); results=(); violations=(); failures=0
executors() { colonies executor ls --type "$TYPE" 2>/dev/null | grep -c -- "$TYPE" || true; }
executors_are() { [[ "$(executors)" == "$1" ]]; }
cr_synced() { [[ "$(kubectl -n "$order" get blueprints -o jsonpath='{.items[*].status.synced}')" == true ]]; }
cr_gone() { [[ -z "$(kubectl -n "$order" get blueprints -o name 2>/dev/null)" ]]; }
cr_replicas() { kubectl -n "$order" get blueprints -o jsonpath='{.items[0].spec.data.replicas}' 2>/dev/null || true; }
bundle_char() { osl_service_char "$cfs_service" "$1"; }
part_running() { osl_service_char "$rfs_service" status.currentData.runningInstances; }
part_reports_running() { [[ -n "$(part_running)" ]]; }
order_completed() { [[ "$(osl GET "/serviceOrdering/v4/serviceOrder/$1" | jq -r .state)" == COMPLETED ]]; }
# The processes waiting for this test's executor-type family. "process psw" lists 20 by default,
# at most 100 (the server's MaxCount), and prints nothing at all when none wait; hence the count
# (QUEUE_N must stay below 100) and the default.
waiting_family() {
	local n
	n="$(colonies process psw --count 100 --json 2>/dev/null |
		jq -r --arg t "$TYPE" '[.[]? | select(.spec.conditions.executortype | startswith($t))] | length' 2>/dev/null)" || true
	echo "${n:-0}"
}
stamp() { date +%H:%M:%S; }
passed() { results+=("$1"); ok "$1"; }
failed() {
	results+=("$1"); failures=$((failures + 1)); warn "$1"
	echo "   --- bundle service notes" >&2; osl_service_notes "$cfs_service" 8 | sed 's/^/   /' >&2
}

# sample: read the loop's state once, print it when it changed, and check the invariants (5).
q="" r="" c="" x="" p="" w="" last_line="" t0=0
sample() {
	q="$(bundle_char queueWaiting || true)"; r="$(bundle_char replicas || true)"; c="$(cr_replicas)"; x="$(executors)"; p="$(part_running || true)"; w="$(waiting_family)"
	local line="waiting=$w queueWaiting=$q replicas=$r CR=$c executors=$x running(part)=$p"
	if [[ "$line" != "$last_line" ]]; then echo "   +$((SECONDS - t0))s $line" >&2; last_line=$line; fi
	if [[ "$r" =~ ^[0-9]+$ ]]; then
		if ((r > MAX_REPLICAS)); then violations+=("replicas=$r above maxReplicas=$MAX_REPLICAS at +$((SECONDS - t0))s"); fi
		if [[ "$p" =~ ^[0-9]+$ ]] && ((r > p + 1)); then violations+=("replicas=$r while the part reports $p running at +$((SECONDS - t0))s: the rule stepped ahead"); fi
	fi
}
scaled_to() { [[ "$x" == "$1" && "$c" == "$1" ]]; }
queue_empty() { [[ "$q" == 0 ]]; }
# until_within <seconds> <label> <condition...>: sample every 5 s until the condition holds.
until_within() {
	local secs=$1 label=$2 t1=$SECONDS deadline=$((SECONDS + $1))
	shift 2
	while :; do
		sample
		if "$@"; then passed "$label after $((SECONDS - t1))s"; return 0; fi
		if ((SECONDS >= deadline)); then failed "$label: not within ${secs}s"; return 0; fi
		sleep 5
	done
}

cleanup() {
	set +e
	[[ -n "$reporter_pid" ]] && kill "$reporter_pid" 2>/dev/null
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

# --- The reporter's account
if [[ -n "${REPORTER_USER:-}" ]]; then
	rep_user=$REPORTER_USER rep_password=${REPORTER_PASSWORD:?REPORTER_USER needs REPORTER_PASSWORD}
elif [[ "$OPENSLICE" == local ]]; then
	rep_user=reporter; rep_password="$("$ROOT/scripts/osl-user.sh" reporter USER)"
else
	rep_user=$OSL_USER rep_password=$OSL_PASSWORD
fi
rep_token="$(OSL_USER=$rep_user OSL_PASSWORD=$rep_password osl_login && echo "$OSL_TOKEN")"

info "scale on queue $(stamp): RFS '$RFSNAME', bundle '$CFSSNAME' on $RSPEC; reporter $rep_user"
rfss="$(osl_cr_rfss "$RFSNAME" "$RSPEC" "$CR" status.currentData.runningInstances 1)"
cfss="$(osl_cfss_chars "$CFSSNAME" "$rfss" "$(jq -n --arg up "$SCALE_UP_QUEUE" --arg max "$MAX_REPLICAS" \
	'[{name: "replicas", value: "1"}, {name: "maxReplicas", value: $max}, {name: "queueWaiting", value: "0"}, {name: "scaleUpQueue", value: $up}]')")"
rules+=("$(osl_rule "$TAG cr-spec pre-provision" PRE_PROVISION "$cfss" "$STATE/scale-on-queue-crspec.java")")
rules+=("$(osl_rule "$TAG cr-spec supervision" SUPERVISION "$cfss" "$STATE/scale-on-queue-crspec.java")")
rules+=("$(osl_rule "$TAG scale-on-queue" SUPERVISION "$cfss" "$STATE/scale-on-queue-scale.java")")
ok "specs $rfss, $cfss and rules ${rules[*]} created"

# --- 1: creation with replicas=1
t1=$SECONDS
order="$(jq -n --arg id "$cfss" --arg name "$CFSSNAME" --arg up "$SCALE_UP_QUEUE" --arg max "$MAX_REPLICAS" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{
	description: "scale-on-queue test order", requestedStartDate: $now,
	orderItem: [{id: "1", action: "add", service: {name: $name, serviceSpecification: {id: $id, name: $name},
		serviceCharacteristic: [{name: "replicas", value: {value: "1", alias: ""}, valueType: "TEXT"},
		                        {name: "maxReplicas", value: {value: $max, alias: ""}, valueType: "TEXT"},
		                        {name: "queueWaiting", value: {value: "0", alias: ""}, valueType: "TEXT"},
		                        {name: "scaleUpQueue", value: {value: $up, alias: ""}, valueType: "TEXT"}]}}]}' |
	{ osl POST "/serviceOrdering/v4/serviceOrder" "$(cat)"; } | jq -er .id)"
osl_ack "$order"; ok "order $order acknowledged $(stamp)"
retry 180 "the Blueprint CR in namespace $order" cr_synced
retry 180 "one echo executor" executors_are 1
retry 300 "order $order to complete" order_completed "$order"
# The inventory ignores the serviceOrder.id filter and the order item's service is a separate
# record, so find the bundle's service by its unique name.
cfs_service="$(osl GET "/serviceInventory/v4/service" | jq -er --arg n "$CFSSNAME" '[.[] | select(.name==$n and .state!="terminated")][0].id')" ||
	die "no active service named '$CFSSNAME' in the inventory"
rfs_service="$(osl_service "$cfs_service" | jq -r '.supportingService[0].id')"
# The rule steps only when the part reports its running instances, which CRIDGE copies from the
# Blueprint status once a minute.
retry 150 "the part to report status.currentData.runningInstances" part_reports_running
if [[ "$(cr_replicas)" == 1 && "$(part_running)" == 1 ]]; then
	passed "creation: one executor, order COMPLETED, part reports 1 running after $((SECONDS - t1))s"
else
	failed "creation: CR replicas=$(cr_replicas), part reports '$(part_running)' running"
fi

# --- The reporter: every 15 s, PATCH queueWaiting into the bundle's service when it changed
(
	OSL_TOKEN=$rep_token last=""
	while :; do
		n="$(waiting_family)"
		if [[ "$n" != "$last" ]]; then
			if osl_patch_service_char "$cfs_service" queueWaiting "$n"; then last=$n; else warn "reporter: PATCH queueWaiting=$n failed"; fi
		fi
		sleep 15
	done
) &
reporter_pid=$!

# --- Demand: QUEUE_N processes for a sibling type with no executor, waiting QUEUE_TTL seconds.
# Submitted ten at a time: a hundred at once has hung the ColonyOS server (v1.9.10).
info "demand $(stamp): $QUEUE_N processes for $TYPE-none, expiring after ${QUEUE_TTL}s"
for b in $(seq 0 10 $((QUEUE_N - 1))); do
	pids=()
	for i in $(seq $((b + 1)) $((b + 10))); do
		if ((i > QUEUE_N)); then break; fi
		timeout 60 colonies function exec --func echo --args "q$i" --targettype "$TYPE-none" --maxwaittime "$QUEUE_TTL" >/dev/null 2>&1 &
		pids+=($!)
	done
	wait "${pids[@]}" || true
done
t0=$SECONDS
landed="$(waiting_family)"
if ((landed < SCALE_UP_QUEUE)); then die "only $landed of $QUEUE_N processes are waiting; the test needs at least $SCALE_UP_QUEUE"; fi
ok "$landed processes waiting"

# --- 2, 3: scale-up to the cap, one step at a time
until_within 240 "scale-up: 2 executors and CR replicas=2" scaled_to 2
until_within 240 "scale-up: 3 executors and CR replicas=3, the cap" scaled_to 3

# --- 4: scale-down once the queue has expired
left=$((QUEUE_TTL + 90 - (SECONDS - t0)))
if ((left < 60)); then left=60; fi
until_within "$left" "demand gone: queueWaiting=0 in the inventory" queue_empty
until_within 360 "scale-down: 1 executor and CR replicas=1" scaled_to 1

# --- 5: the invariants, over every sample
if ((${#violations[@]} == 0)); then
	passed "pacing: replicas never above $MAX_REPLICAS, never more than one step ahead of the part"
else
	failed "pacing: ${violations[0]} (${#violations[@]} such samples)"
fi

info "termination $(stamp)"
kill "$reporter_pid" 2>/dev/null || true; reporter_pid=""
osl_terminate "$TAG"
retry 240 "the Blueprint CR to be deleted" cr_gone
retry 120 "the executors to be gone" executors_are 0
passed "termination: CR, Blueprint and executors removed"

if ((failures > 0)); then die "scale-on-queue test: $failures unexpected result(s)"; fi
ok "scale-on-queue test passed ($TAG)"
