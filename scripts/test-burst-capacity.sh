#!/usr/bin/env bash
# Test of the burst rules of the scaling-policy catalogue entry (catalog/scaling-policy): the
# scaling loop taken past the domain's cap by OpenSlice LCM rules alone. The main bundle is
# ordered with replicas=1 and maxReplicas=2 and carries the tier-1 rules (test-scale-on-queue.sh)
# plus burst-on-cap; a second bundle, "burst capacity", whose Blueprint names another location,
# carries burst-release. A reporter writes queueWaiting into both bundles from the colony's waiting
# processes. Demand is QUEUE_N processes for a sibling type nobody serves, waiting QUEUE_TTL seconds.
# The test passes when:
#   1  the main order completes with one executor and the part reports its running instances
#   2  within 240 s of the demand, tier 1 is at its cap: two executors and the Blueprint says 2
#   3  within another 240 s, burst-on-cap has placed a service order (burstOrder holds its id),
#      the burst Blueprint is synced at BURST_LOCATION, and four executors run
#   4  that order reaches COMPLETED within 240 s more
#   5  once the queue has expired: burst-release has placed its termination order within 120 s,
#      the burst bundle and its part are terminated and its executors gone within 180 s more,
#      and tier 1 is back to one executor within 360 s more
#   6  at no sample is replicas above maxReplicas, and only one burst order is placed
# Measured on the devstack: burst executors about two minutes after the cap, burst gone about one
# minute after the queue emptied. Takes about twelve minutes.
# Needs a reconciler for BURST_LOCATION (default cloud): make reconciler LOCATION=cloud.
# Logs in like test-scaling-policy.sh (the devstack user, or OSL_URL/OSL_USER/OSL_PASSWORD). The
# reporter logs in as REPORTER_USER/REPORTER_PASSWORD if set; otherwise, with OPENSLICE=local, as
# the user "reporter" that scripts/osl-user.sh creates with the role USER; otherwise as the test's
# own user. A USER-only account lists only its own services, so the reporter finds the bundles
# with the test's token and patches them with its own.
# QUEUE_N (30, below 100), QUEUE_TTL (420), SCALE_UP_QUEUE (10), BURST_LOCATION can be set.
# KEEP=1 leaves everything in place.
source "$(dirname "$0")/lib.sh"
source "$ROOT/scripts/osl.sh"
need kubectl colonies jq curl

if [[ "$OPENSLICE" == local ]]; then
	load_identities; : "${OSL_URL:=$OPENSLICE_URL}" "${OSL_USER:=devstack}" "${OSL_PASSWORD:=$OPENSLICE_PASSWORD}"
fi
: "${OSL_URL:?}" "${OSL_USER:?}" "${OSL_PASSWORD:?}"
QUEUE_N=${QUEUE_N:-30}; QUEUE_TTL=${QUEUE_TTL:-420}; SCALE_UP_QUEUE=${SCALE_UP_QUEUE:-10}
BURST_LOCATION=${BURST_LOCATION:-cloud}; MAX_REPLICAS=2; BURST_REPLICAS=2
colonies_cli_env
osl_login
TEST_TOKEN="$OSL_TOKEN"

# "executor ls" has no JSON output; its table has the columns NAME, TYPE, LOCATION, LAST HEARD FROM.
if ! colonies executor ls 2>/dev/null | grep -qE "│ docker-reconciler +│ +$BURST_LOCATION +│"; then
	die "no docker-reconciler registered for location $BURST_LOCATION; run: make reconciler LOCATION=$BURST_LOCATION"
fi

CAT="$ROOT/catalog/scaling-policy"
RSPEC="Blueprint@colony.colonyos.io/v1@k3d-$CLUSTER_NAME@https://$COLONIES_NODE_HOST:6443/"
TAG="burst-$CLUSTER_NAME-$(date +%s)"
TYPE="$TAG-echo"
RFSNAME="$TAG echo executors"
CFSSNAME="$TAG scaling policy"
BRFSNAME="$TAG burst executors"
BCFSSNAME="$TAG burst capacity"

# fill <location> <part name> <file>: the rule files embed the CR template, so they take the location too
fill() { sed -e "s|@LOCATION@|$1|g" -e "s|@TYPE@|$TYPE|g" -e "s|@IMAGE@|$ECHO_EXECUTOR_IMAGE|g" -e "s|@RFSNAME@|$2|g" "$3"; }
CR="$(fill "$LOCATION_NAME" "$RFSNAME" "$CAT/echo.cr.yaml")"
BCR="$(fill "$BURST_LOCATION" "$BRFSNAME" "$CAT/echo.cr.yaml")"
fill "$LOCATION_NAME" "$RFSNAME" "$CAT/cr-spec-from-replicas.rule.java" >"$STATE/burst-crspec.java"
fill "$BURST_LOCATION" "$BRFSNAME" "$CAT/cr-spec-from-replicas.rule.java" >"$STATE/burst-bcrspec.java"
fill "$LOCATION_NAME" "$RFSNAME" "$CAT/scale-on-queue.rule.java" >"$STATE/burst-scale.java"
fill "$LOCATION_NAME" "$RFSNAME" "$CAT/burst-on-cap.rule.java" >"$STATE/burst-oncap.java"
fill "$BURST_LOCATION" "$BRFSNAME" "$CAT/burst-release.rule.java" >"$STATE/burst-release.java"

rfss="" cfss="" brfss="" bcfss="" order="" cfs_service="" rfs_service="" reporter_pid="" burst_order=""
rules=(); results=(); violations=(); burst_orders_seen=(); failures=0
executors() { colonies executor ls --type "$TYPE" 2>/dev/null | grep -c -- "$TYPE" || true; }
executors_are() { [[ "$(executors)" == "$1" ]]; }
cr_synced() { [[ "$(kubectl -n "$order" get blueprints -o jsonpath='{.items[*].status.synced}')" == true ]]; }
cr_gone() { [[ -z "$(kubectl -n "$1" get blueprints -o name 2>/dev/null)" ]]; }
cr_replicas() { kubectl -n "$1" get blueprints -o jsonpath='{.items[0].spec.data.replicas}' 2>/dev/null || true; }
cr_location() { kubectl -n "$1" get blueprints -o jsonpath='{.items[0].spec.locationName}' 2>/dev/null || true; }
char_of() { osl_service_char "$1" "$2" 2>/dev/null || true; }
part_reports_running() { [[ -n "$(char_of "$rfs_service" status.currentData.runningInstances)" ]]; }
order_state() { osl GET "/serviceOrdering/v4/serviceOrder/$1" 2>/dev/null | jq -r '.state // ""'; }
order_completed() { [[ "$(order_state "$1")" == COMPLETED ]]; }
svc_by_name() { osl GET "/serviceInventory/v4/service" | jq -r --arg n "$1" '[.[] | select(.name==$n and .state!="terminated")][0].id // ""'; }
svc_state_by_name() { osl GET "/serviceInventory/v4/service" | jq -r --arg n "$1" '[.[] | select(.name==$n)] | sort_by(.startDate) | last | .state // ""'; }
# The processes waiting for this test's executor-type family ("process psw" lists 20 by default, at most 100).
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
	echo "   --- main bundle notes" >&2; osl_service_notes "$cfs_service" 6 | sed 's/^/   /' >&2
	local b; b="$(svc_by_name "$BCFSSNAME")"
	if [[ -n "$b" ]]; then echo "   --- burst bundle notes" >&2; osl_service_notes "$b" 6 | sed 's/^/   /' >&2; fi
}

# sample: read the loop's state once, print it when it changed, and check the invariants (6).
q="" r="" c="" x="" bo="" bos="" bloc="" bst="" brel="" last_line="" t0=0
sample() {
	q="$(char_of "$cfs_service" queueWaiting)"; r="$(char_of "$cfs_service" replicas)"; c="$(cr_replicas "$order")"; x="$(executors)"
	bo="$(char_of "$cfs_service" burstOrder)"
	if [[ -n "$bo" && "$bo" != failed && "$bo" != "$burst_order" ]]; then
		burst_order="$bo"; burst_orders_seen+=("$bo")
	fi
	bos="" bloc="" bst="" brel=""
	if [[ -n "$burst_order" ]]; then
		bos="$(order_state "$burst_order")"; bloc="$(cr_location "$burst_order")"
		bst="$(svc_state_by_name "$BCFSSNAME")"
		local bid; bid="$(svc_by_name "$BCFSSNAME")"; [[ -n "$bid" ]] && brel="$(char_of "$bid" released)"
	fi
	local line="queueWaiting=$q replicas=$r CR=$c executors=$x burstOrder=$bo burst: order=$bos CR@$bloc service=$bst released=$brel"
	if [[ "$line" != "$last_line" ]]; then echo "   +$((SECONDS - t0))s $line" >&2; last_line=$line; fi
	if [[ "$r" =~ ^[0-9]+$ ]] && ((r > MAX_REPLICAS)); then violations+=("replicas=$r above maxReplicas=$MAX_REPLICAS at +$((SECONDS - t0))s"); fi
	if [[ "$bo" == failed ]]; then violations+=("burst-on-cap: createServiceOrder returned nothing at +$((SECONDS - t0))s"); fi
	if [[ "$brel" == failed ]]; then violations+=("burst-release: createServiceOrder returned nothing at +$((SECONDS - t0))s"); fi
}
tier1_at_cap() { [[ "$x" == "$MAX_REPLICAS" && "$c" == "$MAX_REPLICAS" ]]; }
burst_running() { [[ -n "$burst_order" && "$bloc" == "$BURST_LOCATION" && "$x" == $((MAX_REPLICAS + BURST_REPLICAS)) ]]; }
burst_completed() { [[ "$bos" == COMPLETED ]]; }
queue_empty() { [[ "$q" == 0 ]]; }
release_placed() { [[ -n "$brel" && "$brel" != failed ]]; }
burst_gone() { [[ "$bst" == terminated ]] && cr_gone "$burst_order" && [[ "$x" -le "$MAX_REPLICAS" ]]; }
back_to_one() { [[ "$x" == 1 && "$c" == 1 ]]; }
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
	[[ "${KEEP:-}" == 1 ]] && { warn "KEEP=1: leaving orders, specs and rules in place"; return; }
	OSL_TOKEN="$TEST_TOKEN"
	if [[ -n "$order" ]]; then
		osl_terminate "$TAG" >/dev/null 2>&1 || warn "could not terminate the services of $TAG"
		local ns; for ns in "$order" $burst_order; do
			for _ in $(seq 40); do cr_gone "$ns" && break; sleep 3; done
			kubectl delete namespace "$ns" --ignore-not-found --wait=false >/dev/null 2>&1
		done
	fi
	local r; for r in "${rules[@]}"; do osl DELETE "/lcmrulesmanagement/v1/lcmRuleSpecification/$r" >/dev/null 2>&1 || warn "rule $r not deleted"; done
	local spec; for spec in $cfss $rfss $bcfss $brfss; do osl DELETE "/serviceCatalogManagement/v4/serviceSpecification/$spec" >/dev/null 2>&1 || warn "spec $spec not deleted"; done
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

info "burst capacity $(stamp): main '$CFSSNAME' at $LOCATION_NAME, burst '$BCFSSNAME' at $BURST_LOCATION; reporter $rep_user"
# the burst bundle first: its specification id is a policy characteristic of the main bundle
brfss="$(osl_cr_rfss "$BRFSNAME" "$RSPEC" "$BCR" status.currentData.runningInstances "$BURST_REPLICAS")"
bcfss="$(osl_cfss_chars "$BCFSSNAME" "$brfss" "$(jq -n --arg r "$BURST_REPLICAS" \
	'[{name:"replicas",value:$r},{name:"maxReplicas",value:$r},{name:"queueWaiting",value:"0"},{name:"released",value:""}]')")"
rules+=("$(osl_rule "$TAG burst cr-spec pre-provision" PRE_PROVISION "$bcfss" "$STATE/burst-bcrspec.java")")
rules+=("$(osl_rule "$TAG burst-release" SUPERVISION "$bcfss" "$STATE/burst-release.java")")
rfss="$(osl_cr_rfss "$RFSNAME" "$RSPEC" "$CR" status.currentData.runningInstances 1)"
chars="$(jq -n --arg m "$MAX_REPLICAS" --arg up "$SCALE_UP_QUEUE" --arg b "$bcfss" --arg bn "$BCFSSNAME" \
	'[{name:"replicas",value:"1"},{name:"maxReplicas",value:$m},{name:"queueWaiting",value:"0"},{name:"scaleUpQueue",value:$up},{name:"burstSpec",value:$b},{name:"burstName",value:$bn},{name:"burstOrder",value:""}]')"
cfss="$(osl_cfss_chars "$CFSSNAME" "$rfss" "$chars")"
rules+=("$(osl_rule "$TAG cr-spec pre-provision" PRE_PROVISION "$cfss" "$STATE/burst-crspec.java")")
rules+=("$(osl_rule "$TAG cr-spec supervision" SUPERVISION "$cfss" "$STATE/burst-crspec.java")")
rules+=("$(osl_rule "$TAG scale-on-queue" SUPERVISION "$cfss" "$STATE/burst-scale.java")")
rules+=("$(osl_rule "$TAG burst-on-cap" SUPERVISION "$cfss" "$STATE/burst-oncap.java")")
ok "specs $rfss, $cfss, $brfss, $bcfss and ${#rules[@]} rules created"

# --- 1: creation with replicas=1
t1=$SECONDS
order="$(jq -n --arg id "$cfss" --arg name "$CFSSNAME" --argjson chars "$chars" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{
	description: "burst capacity test order", requestedStartDate: $now,
	orderItem: [{id: "1", action: "add", service: {name: $name, serviceSpecification: {id: $id, name: $name},
		serviceCharacteristic: [$chars[] | {name: .name, value: {value: .value, alias: ""}, valueType: "TEXT"}]}}]}' |
	{ osl POST "/serviceOrdering/v4/serviceOrder" "$(cat)"; } | jq -er .id)"
osl_ack "$order"; ok "order $order acknowledged $(stamp)"
retry 180 "the Blueprint CR in namespace $order" cr_synced
retry 180 "one echo executor" executors_are 1
retry 300 "order $order to complete" order_completed "$order"
cfs_service="$(svc_by_name "$CFSSNAME")"; [[ -n "$cfs_service" ]] || die "no active service named '$CFSSNAME' in the inventory"
rfs_service="$(osl_service "$cfs_service" | jq -r '.supportingService[0].id')"
retry 150 "the part to report status.currentData.runningInstances" part_reports_running
if [[ "$(cr_replicas "$order")" == 1 && "$(char_of "$rfs_service" status.currentData.runningInstances)" == 1 ]]; then
	passed "creation: one executor, order COMPLETED, part reports 1 running after $((SECONDS - t1))s"
else
	failed "creation: CR replicas=$(cr_replicas "$order"), part reports '$(char_of "$rfs_service" status.currentData.runningInstances)' running"
fi

# --- The reporter: every 15 s, PATCH queueWaiting into every bundle of this run whose value differs
(
	while :; do
		n="$(waiting_family)"
		for id in $(OSL_TOKEN="$TEST_TOKEN" osl GET "/serviceInventory/v4/service" | jq -r --arg t "$TAG " '.[] | select((.name|startswith($t)) and (.name|endswith(" executors")|not) and .state!="terminated") | .id'); do
			cur="$(OSL_TOKEN="$TEST_TOKEN" char_of "$id" queueWaiting)"
			if [[ "$cur" != "$n" ]]; then
				if ! OSL_TOKEN="$rep_token" osl_patch_service_char "$id" queueWaiting "$n"; then warn "reporter: PATCH queueWaiting=$n on $id failed"; fi
			fi
		done
		sleep 15
	done
) &
reporter_pid=$!

# --- Demand, ten submissions at a time (a hundred at once has hung the ColonyOS server, v1.9.10)
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

# --- 2, 3, 4: tier 1 to the cap, then the burst through an order placed by the rule
until_within 240 "tier 1 at the cap: $MAX_REPLICAS executors and CR replicas=$MAX_REPLICAS" tier1_at_cap
until_within 240 "burst: order placed by the rule, Blueprint at $BURST_LOCATION, $((MAX_REPLICAS + BURST_REPLICAS)) executors" burst_running
until_within 240 "burst: order COMPLETED" burst_completed

# --- 5: release once the queue has expired
left=$((QUEUE_TTL + 90 - (SECONDS - t0)))
if ((left < 60)); then left=60; fi
until_within "$left" "demand gone: queueWaiting=0 in the inventory" queue_empty
until_within 120 "release: termination order placed by the burst bundle" release_placed
until_within 180 "release: burst bundle and part terminated, Blueprint and executors gone" burst_gone
until_within 360 "tier 1 back to 1 executor and CR replicas=1" back_to_one

# --- 6: the invariants
if ((${#burst_orders_seen[@]} > 1)); then violations+=("${#burst_orders_seen[@]} burst orders placed: ${burst_orders_seen[*]}"); fi
if ((${#violations[@]} == 0)); then
	passed "invariants: replicas never above $MAX_REPLICAS, one burst order, no failed createServiceOrder"
else
	failed "invariants: ${violations[0]} (${#violations[@]} findings)"
fi
if [[ -n "$burst_order" ]]; then
	echo "   --- burst order $burst_order: $(osl GET "/serviceOrdering/v4/serviceOrder/$burst_order" | jq -c '{state, notes: [.note[]?.text | select(startswith("Order created"))], requester: [.relatedParty[]?.name]}')" >&2
fi

info "termination $(stamp)"
kill "$reporter_pid" 2>/dev/null || true; reporter_pid=""
osl_terminate "$TAG"
retry 240 "the Blueprint CR to be deleted" cr_gone "$order"
retry 120 "the executors to be gone" executors_are 0
passed "termination: CR, Blueprint and executors removed"

if ((failures > 0)); then die "burst capacity test: $failures unexpected result(s)"; fi
ok "burst capacity test passed ($TAG)"
