#!/usr/bin/env bash
# Create or update a user of the local OpenSlice (OPENSLICE=local) in Keycloak's realm "openslice":
#   osl-user.sh <username> [ROLE,ROLE,...]
# The user gets exactly the realm roles listed (OpenSlice's are ADMIN, USER, MENTOR, NFV_DEVELOPER,
# EXPERIMENTER, TESTBED_PROVIDER; the TMF APIs need USER for orders and the inventory, ADMIN for
# deleting orders) and a password: OSL_USER_PASSWORD if set, else a generated one. The password is
# printed as the only line on stdout. This is step 3 of joining in the README (the account the
# platform logs in with) and the way to give a program its own account.
source "$(dirname "$0")/lib.sh"
need kubectl curl jq openssl
[[ "$OPENSLICE" == local ]] || die "osl-user.sh manages users of the local OpenSlice only (OPENSLICE=$OPENSLICE)"
username=${1:?usage: osl-user.sh <username> [ROLE,ROLE,...]}
roles=${2:-USER}
NS=openslice; ROOTURL="$OPENSLICE_URL"

admin_pw="$(kubectl -n "$NS" get secret -o json |
	jq -r '.items[] | select(.data["admin-password"]) | .data["admin-password"]' | head -1 | base64 -d)"
[[ -n "$admin_pw" ]] || die "Keycloak admin password not found in namespace $NS"
token="$(curl -sf "$ROOTURL/auth/realms/master/protocol/openid-connect/token" \
	-d grant_type=password -d client_id=admin-cli -d username=admin --data-urlencode "password=$admin_pw" |
	jq -er '.access_token // empty')" || die "Keycloak admin login at $ROOTURL failed"
auth=(-H "Authorization: Bearer $token" -H "Content-Type: application/json")
api="$ROOTURL/auth/admin/realms/openslice"

uid="$(curl -sf "${auth[@]}" "$api/users?username=$username&exact=true" | jq -r '.[0].id // empty')"
if [[ -z "$uid" ]]; then
	jq -n --arg u "$username" '{username: $u, enabled: true, email: ($u + "@localhost"), emailVerified: true, firstName: $u, lastName: "devstack"}' |
		curl -sf "${auth[@]}" "$api/users" -d @- >/dev/null
	uid="$(curl -sf "${auth[@]}" "$api/users?username=$username&exact=true" | jq -er '.[0].id')"
fi
password="${OSL_USER_PASSWORD:-$(openssl rand -hex 12)}"
jq -n --arg p "$password" '{type: "password", value: $p, temporary: false}' |
	curl -sf "${auth[@]}" -X PUT "$api/users/$uid/reset-password" -d @- >/dev/null

# Exactly the roles asked for: drop the current realm roles, then add these.
current="$(curl -sf "${auth[@]}" "$api/users/$uid/role-mappings/realm")"
[[ "$(jq length <<<"$current")" == 0 ]] ||
	curl -sf "${auth[@]}" -X DELETE "$api/users/$uid/role-mappings/realm" -d "$current" >/dev/null
if [[ -n "$roles" && "$roles" != none ]]; then
	wanted="$(curl -sf "${auth[@]}" "$api/roles" | jq --arg r "$roles" '[.[] | select(.name as $n | ($r | split(",")) | index($n))]')"
	[[ "$(jq length <<<"$wanted")" == "$(tr ',' '\n' <<<"$roles" | wc -l | tr -d ' ')" ]] ||
		die "unknown role in '$roles'; the realm has: $(curl -sf "${auth[@]}" "$api/roles" | jq -r '[.[].name] | join(", ")')"
	curl -sf "${auth[@]}" "$api/users/$uid/role-mappings/realm" -d "$wanted" >/dev/null
fi
ok "OpenSlice user $username with realm roles [${roles}]"
echo "$password"
