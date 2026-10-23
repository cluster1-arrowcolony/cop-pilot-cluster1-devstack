# Shared helpers for the devstack scripts. Source it; don't run it.
# shellcheck shell=bash
# shellcheck disable=SC2034 # the variables defined here are used by the scripts that source this file

set -euo pipefail
# Let a failing command inside $(...) stop the substitution too (bash 4.4+). macOS's bash 3.2
# lacks this, so functions that run in a substitution still check their own steps.
shopt -s inherit_errexit 2>/dev/null || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$ROOT/.devstack"
BIN="$STATE/bin"
mkdir -p "$BIN"
export PATH="$BIN:$PATH"

# versions.env pins versions and devstack.env holds local settings. For the variables listed
# here, values already set in the environment (e.g. "make up OPENSLICE=local") win over both.
SETTINGS=(CLUSTER_NAME OPENSLICE COLONY_NAME LOCATION_NAME COLONIES_HOST_PORT API_HOST_PORT
	OPENSLICE_URL OPENSLICE_HOST_PORT OPENSLICE_BIND
	KOLONY_SRC KOLONY_GIT KOLONY_REF IMAGE_CACHE CRIDGE_RESOURCES ARGOCD ARGOCD_REPOS
	OSL_ICE_URL OSL_ICE_TRANSPORT OSL_ICE_BROKER OSL_ICE_ZITI_IDENTITY OSL_ICE_ZITI_SERVICE OSL_ICE_SSH OSL_ICE_SSH_KEY OSL_ICE_SSH_KNOWN_HOSTS
	OSL_BROKER_USER OSL_BROKER_PASSWORD OSL_USER OSL_PASSWORD)
# NAME=value pairs rather than an associative array, which macOS's bash 3.2 lacks.
_env_override=()
for _v in "${SETTINGS[@]}"; do
	if [[ -n "${!_v+set}" ]]; then _env_override+=("$_v=${!_v}"); fi
done
# shellcheck source=../versions.env
source "$ROOT/versions.env"
if [[ -f "$ROOT/devstack.env" ]]; then
	# shellcheck source=/dev/null
	source "$ROOT/devstack.env"
fi
# The ${a[@]+...} form keeps bash 3.2 from treating an empty array as unset under set -u.
for _kv in ${_env_override[@]+"${_env_override[@]}"}; do
	printf -v "${_kv%%=*}" '%s' "${_kv#*=}"
done
unset _v _kv _env_override

# Defaults for everything devstack.env may override.
: "${CLUSTER_NAME:=cop1-${USER:-dev}}"
: "${OPENSLICE:=none}"            # none | local | ice
: "${COLONY_NAME:=dev}"
: "${LOCATION_NAME:=devstack}"
: "${COLONIES_HOST_PORT:=50080}"   # ColonyOS API on the host
: "${API_HOST_PORT:=6550}"         # Kubernetes API on the host
: "${KOLONY_SRC:=}"                # local Kolony checkout; empty means clone KOLONY_GIT@KOLONY_REF
: "${IMAGE_CACHE:=on}"             # on | off: registry caches that survive 'make down' (cache.sh)
: "${CRIDGE_RESOURCES:=}"          # your operator's resources CRIDGE may also create (cridge-access.sh)
: "${ARGOCD:=off}"                 # on | off: Argo CD for OpenSlice orders, OPENSLICE=local only (argocd.sh)
: "${ARGOCD_REPOS:=}"              # the chart repositories orders may deploy from through Argo CD
: "${OSL_ICE_URL:=}"               # OPENSLICE=ice: the shared OpenSlice's URL, from its admins

# Docker and Kubernetes names must be lowercase DNS labels; normalise once here.
CLUSTER_NAME="$(echo "$CLUSTER_NAME" | tr '[:upper:]_.' '[:lower:]--')"
export CLUSTER_NAME
export KUBECONFIG="$STATE/kubeconfig"
DOCKER_NETWORK="k3d-$CLUSTER_NAME"
RECONCILER_CONTAINER="devstack-$CLUSTER_NAME-reconciler"
# How containers on the k3d network reach the ColonyOS NodePort.
COLONIES_NODEPORT=30080
COLONIES_NODE_HOST="k3d-$CLUSTER_NAME-server-0"
OPENSLICE_NODEPORT=30090
# How pods inside the cluster reach it.
COLONIES_SVC_HOST="colonies.colonyos.svc.cluster.local"
COLONIES_SVC_PORT=80

if [[ -t 1 ]]; then
	_c_info=$'\e[1;34m' _c_ok=$'\e[1;32m' _c_warn=$'\e[1;33m' _c_err=$'\e[1;31m' _c_off=$'\e[0m'
else
	_c_info="" _c_ok="" _c_warn="" _c_err="" _c_off=""
fi
info() { echo "${_c_info}==>${_c_off} $*" >&2; }
ok() { echo "${_c_ok} ✓${_c_off} $*" >&2; }
warn() { echo "${_c_warn} !${_c_off} $*" >&2; }
die() {
	echo "${_c_err}error:${_c_off} $*" >&2
	exit 1
}

# OPENSLICE=local serves its portal and APIs at OPENSLICE_URL, which must be the address its users
# and peers call it by: Keycloak names a token's issuer after the Host it was requested at, and
# the OpenSlice services accept only tokens issued at this URL. The port is published on the host
# at OPENSLICE_BIND:OPENSLICE_HOST_PORT, the URL's own address and port when the URL names an IPv4
# address (as when SIF forwards to it), else on loopback.
if [[ -z "${OPENSLICE_URL:-}" ]]; then
	OPENSLICE_URL="http://openslice.localhost:${OPENSLICE_HOST_PORT:-8090}"
fi
OPENSLICE_URL="${OPENSLICE_URL%/}"
[[ "$OPENSLICE_URL" =~ ^http://([A-Za-z0-9.-]+)(:([0-9]+))?$ ]] ||
	die "OPENSLICE_URL must look like http://<host>[:<port>] (got '$OPENSLICE_URL')"
OPENSLICE_HOSTNAME="${BASH_REMATCH[1]}"
_port="${BASH_REMATCH[3]:-80}"
: "${OPENSLICE_HOST_PORT:=$_port}"
[[ "$OPENSLICE_HOST_PORT" == "$_port" ]] ||
	die "OPENSLICE_URL ($OPENSLICE_URL) has port $_port but OPENSLICE_HOST_PORT=$OPENSLICE_HOST_PORT; set only one of them"
unset _port
openslice_url_is_ip() { [[ "$OPENSLICE_HOSTNAME" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
if openslice_url_is_ip; then
	: "${OPENSLICE_BIND:=$OPENSLICE_HOSTNAME}"
fi
: "${OPENSLICE_BIND:=127.0.0.1}"

need() {
	local tool
	for tool in "$@"; do
		command -v "$tool" >/dev/null || die "$tool not found; run 'make tools' (or install $tool)"
	done
}

# retry <seconds> <description> <command...>: run command every 2s until it succeeds. On timeout
# it shows the last lines of the command's last output, so commands must not print secrets.
retry() {
	local timeout=$1 what=$2 out
	shift 2
	local deadline=$((SECONDS + timeout))
	until out="$("$@" 2>&1)"; do
		if ((SECONDS >= deadline)); then
			if [[ -n "$out" ]]; then
				echo "$out" | tail -n 10 | sed 's/^/    /' >&2
			fi
			die "timed out after ${timeout}s waiting for $what"
		fi
		sleep 2
	done
}

# check_port <node port> <wanted host address:port> <settings>: die unless the existing cluster
# publishes that node port at the address the settings now ask for. k3d fixes them at creation.
check_port() {
	local published
	published="$(docker port "$COLONIES_NODE_HOST" "$1/tcp" 2>/dev/null | head -1)" || true
	[[ "$published" == "$2" ]] ||
		die "cluster $CLUSTER_NAME publishes port $1 on '${published:-nothing}', but the settings ($3) ask for $2; run 'make down' and 'make up' to recreate it"
}

# The identities file holds the generated ColonyOS keys; see scripts/colonies.sh.
IDENTITIES="$STATE/identities.env"
load_identities() {
	[[ -f "$IDENTITIES" ]] || die "no identities yet; run 'make up' first"
	# shellcheck source=/dev/null
	source "$IDENTITIES"
}

# Environment for the colonies CLI on the host.
colonies_cli_env() {
	load_identities
	export COLONIES_SERVER_HOST=localhost COLONIES_SERVER_PORT="$COLONIES_HOST_PORT"
	export COLONIES_TLS=false COLONIES_INSECURE=true
	export COLONIES_COLONY_NAME="$COLONY_NAME" COLONIES_COLONY_ID COLONIES_COLONY_PRVKEY
	export COLONIES_PRVKEY="$COLONIES_EXECUTOR_PRVKEY"
	export COLONIES_SERVER_PRVKEY COLONIES_SERVER_ID
}

# "colonies server alive" prints nothing and exits 0 whether or not the server is up,
# so treat any HTTP answer from the API port as alive.
colonies_alive() {
	local code
	code="$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://localhost:$COLONIES_HOST_PORT/api")"
	[[ "$code" != 000 ]]
}

# mask_secrets: filter that hides values of key-, token- and password-like fields in log lines.
mask_secrets() { sed -E 's/([A-Za-z]*([Kk]ey|[Tt]oken|[Pp]assword|[Ss]ecret)[=:] ?"?)[^" ,]+/\1***/g'; }

# diagnostics <namespace>: what usually explains a failed end-to-end test: the Blueprints and
# ColonyProcesses in that namespace with their conditions, and the end of Kolony's and the
# reconciler's logs. Best effort, for use in a failing test's cleanup.
diagnostics() {
	{
		echo "--- Blueprints and ColonyProcesses in $1"
		kubectl -n "$1" get blueprints,colonyprocesses 2>&1
		kubectl -n "$1" get blueprints,colonyprocesses -o jsonpath='{range .items[*]}{.kind}/{.metadata.name}{range .status.conditions[*]}{"\n  "}{.type}={.status} {.reason}: {.message}{end}{"\n"}{end}' 2>&1
		# Kolony follows its errors with stack traces; keep its log entries, which start with a date.
		echo "--- kubectl -n kolony logs deploy/kolony-controller-manager (last 20 entries)"
		kubectl -n kolony logs deploy/kolony-controller-manager --tail 500 2>&1 | grep -E '^[0-9]{4}-' | tail -n 20
		echo "--- docker logs --tail 20 $RECONCILER_CONTAINER"
		docker logs --tail 20 "$RECONCILER_CONTAINER" 2>&1
	} | mask_secrets >&2 || true
}

# quiet <command...>: hide the command's output unless it fails.
quiet() {
	local out
	if ! out="$("$@" 2>&1)"; then
		echo "$out" >&2
		return 1
	fi
}
