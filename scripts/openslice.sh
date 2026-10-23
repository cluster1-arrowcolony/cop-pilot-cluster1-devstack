#!/usr/bin/env bash
# OpenSlice integration, selected by OPENSLICE in devstack.env: none | local | ice.
source "$(dirname "$0")/lib.sh"

case "$OPENSLICE" in
none)
	if [[ "${1:-up}" != down ]]; then
		[[ "$ARGOCD" != on ]] || die "ARGOCD=on needs OPENSLICE=local"
		info "OPENSLICE=none: skipping OpenSlice"
	fi
	;;
local | ice)
	[[ "$ARGOCD" == on || "$ARGOCD" == off ]] || die "ARGOCD must be on or off (got '$ARGOCD')"
	if [[ "$ARGOCD" == on && "$OPENSLICE" != local && "${1:-up}" != down ]]; then
		die "ARGOCD=on needs OPENSLICE=local"
	fi
	if [[ "${1:-up}" == test ]]; then
		"$ROOT/scripts/test-cridge-access.sh"
	fi
	exec "$ROOT/scripts/openslice-$OPENSLICE.sh" "${1:-up}"
	;;
*) die "OPENSLICE must be none, local or ice (got '$OPENSLICE')" ;;
esac
