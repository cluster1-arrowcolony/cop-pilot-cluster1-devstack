#!/usr/bin/env bash
# Build Kolony from source, load it into the cluster, and install it with default credentials.
source "$(dirname "$0")/lib.sh"
need docker k3d kubectl helm git

# Kolony's own namespace, which holds the BlueprintDefinitions, has the full credentials under
# the name Kolony looks for in every namespace. Other namespaces fall back to a Secret without
# the colony key: Blueprints and ColonyProcesses only need the executor key.
OWN_SECRET=colonyos-credentials
DEFAULT_SECRET=colonyos-executor-credentials

# Runs inside $(...), where bash 3.2 ignores set -e, so every step checks its own status.
source_dir() {
	if [[ -n "$KOLONY_SRC" ]]; then
		(cd "$ROOT" && cd "$KOLONY_SRC" && pwd)
		return
	fi
	local dir="$STATE/src/kolony"
	if [[ ! -d "$dir/.git" ]]; then
		git clone --quiet "$KOLONY_GIT" "$dir" || return
	fi
	git -C "$dir" remote set-url origin "$KOLONY_GIT" || return
	# Fetch the ref itself: a local branch of the same name would be stuck at clone time.
	if git -C "$dir" fetch --quiet origin "$KOLONY_REF" 2>/dev/null; then
		git -C "$dir" checkout --quiet --detach FETCH_HEAD || return
	else
		# Not a branch or tag name, e.g. an abbreviated commit: fetch everything and resolve it here.
		git -C "$dir" fetch --quiet --tags origin || return
		git -C "$dir" checkout --quiet --detach "$KOLONY_REF" || return
	fi
	echo "$dir"
}

# check_colonies_client <dir>: warn unless Kolony's go.mod requires the colonies client of the
# deployed server (COLONIES_VERSION). A different client may not speak the server's API.
check_colonies_client() {
	local mod="$1/go.mod" got
	got="$(awk '$1 == "require" { $1 = "" ; $0 = $0 } $1 == "github.com/colonyos/colonies" { print $2; exit }' "$mod")"
	if grep -qE '^[[:space:]]*(replace[[:space:]]+)?github\.com/colonyos/colonies[[:space:]].*=>' "$mod"; then
		warn "Kolony's go.mod replaces github.com/colonyos/colonies; make sure it matches $COLONIES_VERSION"
	elif [[ -z "$got" ]]; then
		warn "github.com/colonyos/colonies not found in $mod; cannot check it against $COLONIES_VERSION"
	elif [[ "$got" != "$COLONIES_VERSION" ]]; then
		warn "Kolony uses colonies $got but the server runs $COLONIES_VERSION (versions.env); run 'go get github.com/colonyos/colonies@$COLONIES_VERSION' in $1"
	fi
}

src="$(source_dir)"
check_colonies_client "$src"
# Tag by commit, plus the tree of the working copy when it differs from the commit (untracked
# files included, ignored ones not), so every source change gets a new image. The throwaway
# index leaves the checkout's own index alone.
rev="$(git -C "$src" rev-parse --short HEAD)"
index="$(mktemp -u)"
tree="$(GIT_INDEX_FILE="$index" git -C "$src" add -A && GIT_INDEX_FILE="$index" git -C "$src" write-tree)"
rm -f "$index"
if [[ "$tree" != "$(git -C "$src" rev-parse 'HEAD^{tree}')" ]]; then
	rev="$rev-dirty-$(cut -c1-8 <<<"$tree")"
fi
image="kolony:devstack-$rev"

if ! docker image inspect "$image" >/dev/null 2>&1; then
	info "building $image from $src"
	quiet docker build -t "$image" "$src"
fi
info "loading $image into $CLUSTER_NAME"
quiet k3d image import "$image" --cluster "$CLUSTER_NAME"

# Helm only installs CRDs on first install, never on upgrade, so apply them directly.
quiet kubectl apply --server-side --force-conflicts -f "$src/config/crd/bases"

load_identities
kubectl create namespace kolony --dry-run=client -o yaml | quiet kubectl apply -f -
# credentials_secret <name> [--from-literal=...]: create or update a ColonyOS credentials Secret.
credentials_secret() {
	local name=$1
	shift
	kubectl -n kolony create secret generic "$name" \
		--from-literal=serverHost="$COLONIES_SVC_HOST" \
		--from-literal=serverPort="$COLONIES_SVC_PORT" \
		--from-literal=tls=false \
		--from-literal=colonyName="$COLONY_NAME" \
		--from-literal=executorPrvKey="$COLONIES_EXECUTOR_PRVKEY" \
		"$@" --dry-run=client -o yaml | quiet kubectl apply -f -
}
credentials_secret "$OWN_SECRET" --from-literal=colonyPrvKey="$COLONIES_COLONY_PRVKEY"
credentials_secret "$DEFAULT_SECRET"
# Earlier devstacks used this name for a default Secret that held the colony key.
quiet kubectl -n kolony delete secret colonyos-default-credentials --ignore-not-found

info "installing Kolony"
# The default credentials only apply in namespaces labelled the way CRIDGE labels the
# namespaces it creates for service orders.
quiet helm upgrade --install kolony "$src/helm/kolony" --namespace kolony \
	--set image.repository=kolony --set image.tag="devstack-$rev" --set image.pullPolicy=Never \
	--set defaultCredentialsSecret="kolony/$DEFAULT_SECRET" \
	--set-string defaultCredentialsNamespaceSelector=org.etsi.osl \
	--wait --timeout 3m

quiet kubectl apply -f "$ROOT/manifests/blueprint-definitions.yaml"
# shellcheck disable=SC2016 # expanded by the inner bash
retry 90 "BlueprintDefinitions to register in ColonyOS" \
	bash -c '[[ "$(kubectl -n kolony get blueprintdefinitions -o jsonpath="{.items[*].status.registered}")" == "true true" ]]'
ok "Kolony $rev running; BlueprintDefinitions registered"
