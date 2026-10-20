#!/usr/bin/env bash
# Enroll an OpenZiti identity for OSL_ICE_TRANSPORT=ziti: turn the one-time enrollment token (JWT)
# from the Ziti admins into an identity file under .devstack/ziti/.
#
#   ziti-enroll.sh <file.jwt>
#
# It runs the pinned ziti CLI image as the current user, so nothing is installed on the host and
# no tunneler runs here; the devstack's broker-tunnel pod uses the identity only to dial the
# broker. The identity file holds the private key: keep it to yourself.
source "$(dirname "$0")/lib.sh"
need docker jq

jwt="${1:-}"
[[ -n "$jwt" ]] || die "usage: make ziti-enroll JWT=<file.jwt>"
[[ -r "$jwt" ]] || die "cannot read $jwt"
name="$(basename "$jwt" .jwt)"
[[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "the token's file name must be letters, digits, '.', '_' or '-' (got '$name')"

dir="$STATE/ziti"
out="$dir/$name.json"
[[ ! -e "$out" ]] || die "$out exists already; a token can be enrolled only once"

claims="$(cut -d. -f2 "$jwt" | jq -Rc 'gsub("-"; "+") | gsub("_"; "/") | @base64d | fromjson' 2>/dev/null)" ||
	die "$jwt is not an enrollment token (JWT)"
exp="$(jq -r '.exp // 0' <<<"$claims")"
(($(date +%s) < exp)) || die "the token expired at $(jq -r '.exp | todate' <<<"$claims"); ask the Ziti admins for a new one"
info "enrolling $name at $(jq -r '.iss' <<<"$claims") (token valid until $(jq -r '.exp | todate' <<<"$claims"))"

mkdir -p "$dir"
chmod 700 "$dir"
# The container sees only $dir, which is under the checkout, so snap Docker can read it too.
if [[ "$(cd "$(dirname "$jwt")" && pwd)/$(basename "$jwt")" != "$dir/$name.jwt" ]]; then
	(umask 077 && cp "$jwt" "$dir/$name.jwt")
fi
quiet docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$dir:/w" \
	"$ZITI_IMAGE" edge enroll "/w/$name.jwt" -o "/w/$name.json"
chmod 600 "$out"
# The token is spent once enrolled.
rm -f "$dir/$name.jwt"

ok "identity in $out"
info "set OSL_ICE_ZITI_IDENTITY=$out in devstack.env"
