# CRIDGE's access to this cluster. Source after lib.sh.
# shellcheck shell=bash

# cridge_kubeconfig: apply manifests/cridge-access.yaml and print the path of a kubeconfig for
# CRIDGE's restricted ServiceAccount. It keeps the cluster and context names of
# kubeconfig.internal, because CRIDGE names this cluster in the OpenSlice catalog after them.
cridge_kubeconfig() {
	# Runs inside $(...): each step returns on failure, as bash 3.2 has no inherit_errexit.
	local out="$STATE/kubeconfig.cridge" token user
	quiet kubectl apply -f "$ROOT/manifests/cridge-access.yaml" || return
	# shellcheck disable=SC2016 # expanded by the inner bash
	retry 60 "the CRIDGE ServiceAccount token" \
		bash -c '[[ -n "$(kubectl -n cridge get secret cridge-token -o jsonpath="{.data.token}")" ]]' || return
	token="$(kubectl -n cridge get secret cridge-token -o jsonpath='{.data.token}' | base64 -d)" || return
	[[ -n "$token" ]] || return

	(umask 077 && cp "$STATE/kubeconfig.internal" "$out") || return
	user="$(kubectl --kubeconfig "$out" config view -o jsonpath='{.contexts[0].context.user}')" || return
	quiet kubectl --kubeconfig "$out" config unset "users.$user.client-certificate-data" || return
	quiet kubectl --kubeconfig "$out" config unset "users.$user.client-key-data" || return
	quiet kubectl --kubeconfig "$out" config set-credentials "$user" --token="$token" || return
	echo "$out"
}
