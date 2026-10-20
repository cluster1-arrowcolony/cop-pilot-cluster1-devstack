#!/usr/bin/env bash
# Check that the local OpenSlice (OPENSLICE=local) answers at OPENSLICE_URL the way a peer such
# as HypO uses it, before it is exposed through SIF and peered. A peer is given that URL and an
# account, logs in with a password grant on the osapiWebClientId client at
# <URL>/auth/realms/openslice/protocol/openid-connect/token, and reads the service catalog.
# Keycloak names a token's issuer after the Host it was requested at, and the OpenSlice services
# accept only tokens issued at their rooturl, so the peer's URL must be OPENSLICE_URL exactly.
#
# Logs in as OSL_USER/OSL_PASSWORD when set (the account the peer will get), else as devstack.
source "$(dirname "$0")/lib.sh"
source "$ROOT/scripts/osl.sh"
need kubectl helm jq curl

[[ "$OPENSLICE" == local ]] || die "peering-check checks the OpenSlice of OPENSLICE=local (OPENSLICE=$OPENSLICE)"
REALM="$OPENSLICE_URL/auth/realms/openslice"

# token_issuer: the iss claim of OSL_TOKEN.
token_issuer() {
	jq -Rr 'split(".")[1] | gsub("-"; "+") | gsub("_"; "/") | @base64d | fromjson | .iss' <<<"$OSL_TOKEN"
}

info "checking OpenSlice as a peer sees it at $OPENSLICE_URL"

rooturl="$(helm get values openslice -n openslice -o json 2>/dev/null | jq -r '.rooturl // empty')" || true
[[ -n "$rooturl" ]] || die "OpenSlice is not deployed; run 'make up'"
[[ "$rooturl" == "$OPENSLICE_URL" ]] ||
	die "OpenSlice runs with rooturl $rooturl, but OPENSLICE_URL is $OPENSLICE_URL; run 'make openslice'"
ok "OpenSlice is deployed for $OPENSLICE_URL"

issuer="$(curl -sf -m 10 "$REALM/.well-known/openid-configuration" | jq -er '.issuer')" ||
	die "no Keycloak realm at $REALM; is $OPENSLICE_HOSTNAME this host, and is the port published at $OPENSLICE_BIND:$OPENSLICE_HOST_PORT (make status)?"
[[ "$issuer" == "$REALM" ]] ||
	die "Keycloak issues tokens at $REALM as $issuer, which the OpenSlice services reject; check Keycloak's frontend URL"
ok "Keycloak issues tokens as $issuer"

if [[ -z "${OSL_USER:-}" ]]; then
	load_identities
	OSL_USER=devstack OSL_PASSWORD="$OPENSLICE_PASSWORD"
fi
[[ -n "${OSL_PASSWORD:-}" ]] || die "OSL_USER is set but OSL_PASSWORD is not"
OSL_URL="$OPENSLICE_URL"
osl_login
ok "logged in as $OSL_USER on osapiWebClientId"

# The catalog reads a peer starts with: categories and customer-facing service specifications.
for path in "/serviceCatalogManagement/v4/serviceCategory" \
	"/serviceCatalogManagement/v4/serviceSpecification?type=CustomerFacingServiceSpecification"; do
	code="$(curl -s -m 30 -o "$STATE/peering-check.json" -w '%{http_code}' \
		-H "Authorization: Bearer $OSL_TOKEN" -H "Accept: application/json" "$OPENSLICE_URL$TMF$path")" || true
	if [[ "$code" == 401 ]]; then
		die "the TMF API rejected a token issued as $(token_issuer); its pods must reach $REALM to validate it (kubectl -n openslice logs deploy/openslice-osscapi)"
	fi
	[[ "$code" == 200 ]] || die "GET $TMF$path answered HTTP $code"
done
count="$(jq 'length' "$STATE/peering-check.json")"
rm -f "$STATE/peering-check.json"
ok "TMF API answers with the catalog ($count customer-facing service specifications)"
if [[ "$count" == 0 ]]; then
	warn "peers list only customer-facing service specifications, and there are none yet"
fi

ok "a peer can use OpenSlice at $OPENSLICE_URL as $OSL_USER"
info "for SIF, the Ziti service forwards to $OPENSLICE_BIND:$OPENSLICE_HOST_PORT on this host, and peers use $OPENSLICE_URL"
