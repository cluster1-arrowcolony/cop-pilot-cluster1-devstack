# CRIDGE's access to this cluster. Source after lib.sh.
# shellcheck shell=bash

# cridge_kubeconfig: apply manifests/cridge-access.yaml and print the path of a kubeconfig for
# CRIDGE's restricted ServiceAccount. It keeps the cluster and context names of
# kubeconfig.internal, because CRIDGE names this cluster in the OpenSlice catalog after them.
cridge_kubeconfig() {
	# Runs inside $(...): each step returns on failure, as bash 3.2 has no inherit_errexit.
	local out="$STATE/kubeconfig.cridge" token user
	quiet kubectl apply -f "$ROOT/manifests/cridge-access.yaml" || return
	cridge_resources || return
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

# cridge_resources: let CRIDGE also create the custom resources listed in CRIDGE_RESOURCES
# ("<plural>.<group>", e.g. widgets.example.com), for an operator of your own that handles
# OpenSlice orders. CRIDGE gets the same rights on them as on Blueprints, and the same limit to
# order namespaces: the policy is a copy of devstack-cridge-namespaces that matches only these
# resources, so its rule is the one test-cridge-access.sh checks. Without the setting, the access
# is removed again. What an order may ask of the operator is up to the operator to check.
cridge_resources() {
	# Runs inside $(...): each step returns on failure, as bash 3.2 has no inherit_errexit.
	local r rules="" vap
	if [[ -z "${CRIDGE_RESOURCES// /}" ]]; then
		quiet kubectl delete clusterrolebinding,clusterrole devstack-cridge-resources --ignore-not-found || return
		quiet kubectl delete validatingadmissionpolicybinding,validatingadmissionpolicy devstack-cridge-resources --ignore-not-found || return
		return
	fi
	for r in $CRIDGE_RESOURCES; do
		[[ "$r" =~ ^[a-z0-9-]+\.[a-z0-9.-]+\.[a-z0-9-]+$ ]] ||
			die "CRIDGE_RESOURCES entries are <plural>.<group> of a custom resource, e.g. widgets.example.com (got '$r')"
		case "${r#*.}" in
		*k8s.io | *kubernetes.io | *colonyos.io | *cattle.io)
			die "CRIDGE_RESOURCES may only name your own resources, not $r"
			;;
		esac
		rules="$rules{\"apiGroups\":[\"${r#*.}\"],\"resources\":[\"${r%%.*}\"]},"
	done
	rules="[${rules%,}]"
	# shellcheck disable=SC2016 # jq program
	jq -n --argjson rules "$rules" '{
		apiVersion: "rbac.authorization.k8s.io/v1", kind: "List", items: [
			{apiVersion: "rbac.authorization.k8s.io/v1", kind: "ClusterRole",
			 metadata: {name: "devstack-cridge-resources"},
			 rules: [$rules[] | . + {verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]}]},
			{apiVersion: "rbac.authorization.k8s.io/v1", kind: "ClusterRoleBinding",
			 metadata: {name: "devstack-cridge-resources"},
			 roleRef: {apiGroup: "rbac.authorization.k8s.io", kind: "ClusterRole", name: "devstack-cridge-resources"},
			 subjects: [{kind: "ServiceAccount", name: "cridge", namespace: "cridge"}]}]}' |
		quiet kubectl apply -f - || return
	vap="$(kubectl get validatingadmissionpolicy devstack-cridge-namespaces -o json)" || return
	jq --argjson rules "$rules" '{
		apiVersion, kind, metadata: {name: "devstack-cridge-resources"},
		spec: (.spec | .matchConstraints.resourceRules =
			[$rules[] | . + {apiVersions: ["*"], operations: ["CREATE", "UPDATE", "DELETE"]}])}' <<<"$vap" |
		quiet kubectl apply -f - || return
	printf '%s\n' '{"apiVersion":"admissionregistration.k8s.io/v1","kind":"ValidatingAdmissionPolicyBinding","metadata":{"name":"devstack-cridge-resources"},"spec":{"policyName":"devstack-cridge-resources","validationActions":["Deny"]}}' |
		quiet kubectl apply -f - || return
	info "CRIDGE may also create $CRIDGE_RESOURCES in order namespaces"
}
