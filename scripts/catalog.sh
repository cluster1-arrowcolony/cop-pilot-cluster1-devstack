#!/usr/bin/env bash
# Catalog tools for the OpenSlice that OPENSLICE points at (local or ice).
#
#   catalog.sh retarget "<RFSS name>" ["<new name>"]
#
# A CR-based resource-facing service spec is bound to one cluster: its resourceSpecification is
# "<Kind>@<group>/<version>@<cluster>@<API URL>" and its currentContextCluster/clusterMasterURL
# characteristics tell OSOM which CRIDGE should deploy it. retarget clones such a spec and points
# the clone at this devstack's cluster, so a spec written for another cluster can be ordered here.
source "$(dirname "$0")/lib.sh"
source "$ROOT/scripts/osl.sh"
need jq curl

case "$OPENSLICE" in
local)
	load_identities
	OSL_URL="$OPENSLICE_URL" OSL_USER=devstack OSL_PASSWORD="$OPENSLICE_PASSWORD"
	;;
ice)
	[[ -n "$OSL_ICE_URL" ]] || die "set OSL_ICE_URL (the ICE OpenSlice's URL)"
	OSL_URL="$OSL_ICE_URL"
	[[ -n "${OSL_USER:-}" && -n "${OSL_PASSWORD:-}" ]] || die "set OSL_USER and OSL_PASSWORD (your ICE OpenSlice account)"
	;;
*) die "set OPENSLICE=local or OPENSLICE=ice" ;;
esac

CONTEXT="k3d-$CLUSTER_NAME"
MASTER_URL="https://$COLONIES_NODE_HOST:6443/"

retarget() {
	local name=${1:?usage: catalog.sh retarget \"<RFSS name>\" [\"<new name>\"]} new_name=${2:-} src rs_old rs_new clone
	osl_login

	src="$(osl GET "/serviceCatalogManagement/v4/serviceSpecification" |
		jq -ce --arg n "$name" '[.[] | select(.name == $n)] | if length == 1 then .[0] else empty end')" ||
		die "need exactly one service specification named '$name'"
	src="$(osl GET "/serviceCatalogManagement/v4/serviceSpecification/$(jq -r .id <<<"$src")")"
	jq -e '[.serviceSpecCharacteristic[].name] | index("_CR_SPEC")' <<<"$src" >/dev/null ||
		die "'$name' has no _CR_SPEC characteristic; only CR-based RFSSs can be retargeted"

	rs_old="$(jq -r '.resourceSpecification[0].name // empty' <<<"$src")"
	[[ "$rs_old" == *@*@*@* ]] || die "'$name' does not reference a CRIDGE resource spec (got '$rs_old')"
	# Kind@group/version stays; cluster and URL become ours.
	rs_new="$(osl_resource_spec "${rs_old%%@*}@$(cut -d@ -f2 <<<"$rs_old")@$CONTEXT@$MASTER_URL")"
	[[ -n "$new_name" ]] || new_name="$name ($CLUSTER_NAME)"

	info "cloning '$name' for $CONTEXT"
	clone="$(osl GET "/serviceCatalogManagement/v4/serviceSpecification/$(jq -r .id <<<"$src")/clone" | jq -er '.id // empty')"
	# PATCH drops characteristics that are not listed, so send all of them.
	jq --arg name "$new_name" --arg ctx "$CONTEXT" --arg url "$MASTER_URL" --argjson rs "$rs_new" '
		def setval($v): .serviceSpecCharacteristicValue = [{value: {value: $v, alias: ""}, valueType: "TEXT", isDefault: true}];
		{
			name: $name, lifecycleStatus: "Active",
			resourceSpecification: [{id: $rs.id, name: $rs.name, "@type": $rs["@type"]}],
			serviceSpecCharacteristic: [.serviceSpecCharacteristic[] | del(.id, .uuid) |
				if .name == "currentContextCluster" then setval($ctx)
				elif .name == "clusterMasterURL" then setval($url)
				else . end]
		}' <<<"$src" >"$STATE/retarget.json"
	osl PATCH "/serviceCatalogManagement/v4/serviceSpecification/$clone" "$(cat "$STATE/retarget.json")" >/dev/null
	ok "created '$new_name' ($clone) targeting $CONTEXT@$MASTER_URL"
	echo "$clone"
}

"${@:-retarget}"
