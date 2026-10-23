#!/usr/bin/env bash
# OPENSLICE=local: run OpenSlice in the devstack cluster, with CRIDGE managing that same cluster.
#
# One URL, OPENSLICE_URL (default http://openslice.localhost:8090), serves the browser, peers and
# the pods, because the services validate tokens against it. On the host, k3d publishes the port
# at OPENSLICE_BIND (browsers and curl resolve *.localhost to loopback). Pods reach a host name
# through a CoreDNS rewrite to the ingress service, and an IP address through the host.
source "$(dirname "$0")/lib.sh"
source "$ROOT/scripts/cridge-access.sh"
source "$ROOT/scripts/argocd.sh"
need kubectl helm git jq curl openssl docker

NS=openslice
ROOTURL="$OPENSLICE_URL"

# chart_dir: clone the OpenSlice release once and print its chart directory.
# Runs inside $(...), where bash 3.2 ignores set -e, so every step checks its own status. The
# clone goes to a temporary name first, so an interrupted one is not taken for a complete one.
chart_dir() {
	local dir="$STATE/src/openslice-$OPENSLICE_REF"
	if [[ ! -d "$dir" ]]; then
		info "fetching OpenSlice $OPENSLICE_REF chart"
		rm -rf "$dir.tmp" || return
		git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$OPENSLICE_REF" "$OPENSLICE_GIT" "$dir.tmp" || return
		mv "$dir.tmp" "$dir" || return
	fi
	[[ -f "$dir/kubernetes/helm/openslice/Chart.yaml" ]] || return
	echo "$dir/kubernetes/helm/openslice"
}

# The chart reads the web UI configs from files/ and only ships *.default versions of them.
prepare_chart() {
	local tmf="$1/files/org.etsi.osl.tmf.web/src/assets/config" portal="$1/files/org.etsi.osl.portal.web/src/js"
	sed "s#{BASEURL}#$ROOTURL#g" "$tmf/config.prod.default.json" >"$tmf/config.prod.json"
	cp "$tmf/config.theming.default.json" "$tmf/config.theming.json"
	cp "$tmf/theming.default.scss" "$tmf/theming.scss"
	cp "$portal/config.js.default" "$portal/config.js"
}

# The chart's own passwords are public (Keycloak admin Pa55w0rd, MySQL letmein and 12345, broker
# artemis), and the ingress serves Keycloak's admin console at ROOTURL/auth. So a new install gets
# generated ones, kept in identities.env.
CREDENTIALS=(OPENSLICE_KEYCLOAK_ADMIN_PASSWORD OPENSLICE_BROKER_PASSWORD OPENSLICE_DB_ROOT_PASSWORD
	OPENSLICE_DB_KEYCLOAK_PASSWORD OPENSLICE_DB_TMF_PASSWORD OPENSLICE_DB_PORTAL_PASSWORD OPENSLICE_DB_METRICO_PASSWORD)

# credentials: generate the missing ones and print the chart values that use them. MySQL's root
# and Keycloak's admin password only take effect when their data is first created, so a release
# installed with the chart's passwords keeps them, with a warning, until it is recreated.
credentials() {
	local v
	if ! grep -q '^OPENSLICE_KEYCLOAK_ADMIN_PASSWORD=' "$IDENTITIES" && helm status openslice -n "$NS" >/dev/null 2>&1; then
		warn "OpenSlice was installed with the chart's public passwords, so anyone who reaches $ROOTURL/auth can administer it; 'make down' and 'make up' to recreate it with generated ones"
		return
	fi
	for v in "${CREDENTIALS[@]}"; do
		if ! grep -q "^$v=" "$IDENTITIES"; then
			echo "$v=$(openssl rand -hex 16)" >>"$IDENTITIES"
		fi
	done
	load_identities
	cat <<-YAML
		oscreds:
		  activemq:
		    password: "$OPENSLICE_BROKER_PASSWORD"
		  mysql:
		    password: "$OPENSLICE_DB_ROOT_PASSWORD"
		    keycloak:
		      password: "$OPENSLICE_DB_KEYCLOAK_PASSWORD"
		      adminpassword: "$OPENSLICE_KEYCLOAK_ADMIN_PASSWORD"
		    tmf:
		      password: "$OPENSLICE_DB_TMF_PASSWORD"
		    portal:
		      password: "$OPENSLICE_DB_PORTAL_PASSWORD"
		    metrico:
		      password: "$OPENSLICE_DB_METRICO_PASSWORD"
	YAML
}

ingress() {
	info "installing ingress-nginx $INGRESS_NGINX_CHART_VERSION"
	quiet helm upgrade --install ingress-nginx ingress-nginx \
		--repo https://kubernetes.github.io/ingress-nginx --version "$INGRESS_NGINX_CHART_VERSION" \
		--namespace ingress-nginx --create-namespace \
		--set controller.service.type=NodePort \
		--set controller.service.ports.http="$OPENSLICE_HOST_PORT" \
		--set controller.service.nodePorts.http="$OPENSLICE_NODEPORT" \
		--set controller.service.enableHttps=false \
		--set controller.admissionWebhooks.enabled=false \
		--wait --timeout 5m

	if openslice_url_is_ip; then
		kubectl -n kube-system delete configmap coredns-custom --ignore-not-found >/dev/null
	else
		# k3s merges *.override snippets from this ConfigMap into the main CoreDNS server block.
		kubectl apply -f - >/dev/null <<-YAML
			apiVersion: v1
			kind: ConfigMap
			metadata:
			  name: coredns-custom
			  namespace: kube-system
			data:
			  openslice.override: |
			    rewrite stop {
			      name exact $OPENSLICE_HOSTNAME. ingress-nginx-controller.ingress-nginx.svc.cluster.local.
			      answer name ingress-nginx-controller.ingress-nginx.svc.cluster.local. $OPENSLICE_HOSTNAME.
			    }
		YAML
	fi
	quiet kubectl -n kube-system rollout restart deployment coredns
	quiet kubectl -n kube-system rollout status deployment coredns --timeout 120s
}

up() {
	local chart values kubeconfig tag="$OPENSLICE_REF"
	check_port "$OPENSLICE_NODEPORT" "$OPENSLICE_BIND:$OPENSLICE_HOST_PORT" "OPENSLICE_URL/OPENSLICE_BIND"
	chart="$(chart_dir)" ||
		die "no OpenSlice $OPENSLICE_REF chart from $OPENSLICE_GIT; if $STATE/src/openslice-$OPENSLICE_REF is incomplete, delete it"
	prepare_chart "$chart"
	ingress
	kubeconfig="$(cridge_kubeconfig)"
	if [[ "$ARGOCD" == on ]]; then
		argocd_up
	else
		argocd_down
	fi
	if [[ "$OPENSLICE_BIND" != 127.* ]]; then
		warn "OpenSlice is published on $OPENSLICE_BIND:$OPENSLICE_HOST_PORT, over plain HTTP, to everyone who can reach that address; Docker's port rules bypass host firewalls such as ufw"
	fi

	values="$STATE/openslice-values.yaml"
	(
		umask 077
		{
			credentials
			echo "rooturl: $ROOTURL"
			echo "image:"
			for c in bugzilla:bugzilla centrallog:centrallog.service manoclient:mano osom:osom \
				portalapi:portal.api osscapi:tmf.api oasapi:oas portalweb:portal.web tmfweb:tmf.web \
				cridge:cridge metrico:metrico mcpserver:mcp.server mcpbackend:mcp.backend; do
				echo "  ${c%%:*}:"
				echo "    repository: $OPENSLICE_REGISTRY/org.etsi.osl.${c#*:}"
				echo "    tag: \"$tag\""
				echo "    pullPolicy: IfNotPresent"
			done
			echo "cridge:"
			echo "  kubeconfig:"
			echo "    base64: $(base64 <"$kubeconfig" | tr -d '\n')"
		} >"$values"
	)
	info "installing OpenSlice $OPENSLICE_REF (first start pulls ~5 GB and takes several minutes)"
	quiet helm upgrade --install openslice "$chart" --namespace "$NS" --create-namespace \
		--values "$values" --timeout 20m --wait

	retry 600 "OpenSlice TMF API at $ROOTURL" \
		bash -c "curl -sf -o /dev/null '$ROOTURL/tmf-api/serviceCatalogManagement/v4/serviceSpecification' -H 'Accept: application/json' || [[ \$(curl -s -o /dev/null -w '%{http_code}' '$ROOTURL/tmf-api/serviceCatalogManagement/v4/serviceSpecification') == 401 ]]"
	# CRIDGE registers the cluster only at startup and gives up if the catalog is not ready yet.
	quiet kubectl -n "$NS" rollout restart deployment openslice-cridge
	quiet kubectl -n "$NS" rollout status deployment openslice-cridge --timeout 300s
	keycloak
	ok "OpenSlice at $ROOTURL"
}

# keycloak: point the portal's client at ROOTURL and create the user "devstack" with every
# OpenSlice role (the realm ships without users). Keycloak imports the realm, with the URL the
# chart had then, only on its first start, so a changed OPENSLICE_URL is applied here.
keycloak() {
	local admin_pw token auth client uid password
	if ! grep -q '^OPENSLICE_PASSWORD=' "$IDENTITIES"; then
		echo "OPENSLICE_PASSWORD=$(openssl rand -hex 12)" >>"$IDENTITIES"
	fi
	load_identities
	password="$OPENSLICE_PASSWORD"

	admin_pw="$(kubectl -n "$NS" get secret -o json |
		jq -r '.items[] | select(.data["admin-password"]) | .data["admin-password"]' | head -1 | base64 -d)"
	[[ -n "$admin_pw" ]] || die "Keycloak admin password not found in namespace $NS"
	token="$(curl -sf "$ROOTURL/auth/realms/master/protocol/openid-connect/token" \
		-d grant_type=password -d client_id=admin-cli -d username=admin --data-urlencode "password=$admin_pw" |
		jq -er '.access_token // empty')" || die "Keycloak admin login at $ROOTURL failed"
	auth=(-H "Authorization: Bearer $token" -H "Content-Type: application/json")
	local api="$ROOTURL/auth/admin/realms/openslice"

	client="$(curl -sf "${auth[@]}" "$api/clients?clientId=osapiWebClientId" | jq -c '.[0] // empty')"
	[[ -n "$client" ]] || die "Keycloak client osapiWebClientId not found in realm openslice"
	jq --arg u "$ROOTURL" '.rootUrl = $u | .adminUrl = $u
		| .redirectUris = (.redirectUris + [$u + "/*"] | unique) | .webOrigins = (.webOrigins + [$u] | unique)' <<<"$client" |
		curl -sf "${auth[@]}" -X PUT "$api/clients/$(jq -r .id <<<"$client")" -d @- >/dev/null

	uid="$(curl -sf "${auth[@]}" "$api/users?username=devstack&exact=true" | jq -r '.[0].id // empty')"
	if [[ -z "$uid" ]]; then
		curl -sf "${auth[@]}" "$api/users" -d '{"username":"devstack","enabled":true,"email":"devstack@localhost","emailVerified":true,"firstName":"Dev","lastName":"Stack"}' >/dev/null
		uid="$(curl -sf "${auth[@]}" "$api/users?username=devstack&exact=true" | jq -r '.[0].id')"
	fi
	curl -sf "${auth[@]}" -X PUT "$api/users/$uid/reset-password" \
		-d "{\"type\":\"password\",\"value\":\"$password\",\"temporary\":false}" >/dev/null
	curl -sf "${auth[@]}" "$api/roles" |
		jq '[.[] | select(.name | test("^(ADMIN|USER|MENTOR|NFV_DEVELOPER|EXPERIMENTER|TESTBED_PROVIDER|OSL_AUTOACK_ORDER)$"))]' |
		curl -sf "${auth[@]}" "$api/users/$uid/role-mappings/realm" -d @- >/dev/null
	ok "OpenSlice user devstack (password in $IDENTITIES as OPENSLICE_PASSWORD)"
}

e2e() {
	load_identities
	OSL_URL="$ROOTURL" OSL_USER=devstack OSL_PASSWORD="$OPENSLICE_PASSWORD" "$ROOT/scripts/test-openslice.sh"
	if [[ "$ARGOCD" == on ]]; then
		OSL_URL="$ROOTURL" OSL_USER=devstack OSL_PASSWORD="$OPENSLICE_PASSWORD" "$ROOT/scripts/test-argocd.sh"
	fi
}

down() {
	helm uninstall openslice -n "$NS" >/dev/null 2>&1 || true
	helm uninstall argocd -n "$ARGOCD_NS" >/dev/null 2>&1 || true
	helm uninstall ingress-nginx -n ingress-nginx >/dev/null 2>&1 || true
	kubectl -n kube-system delete configmap coredns-custom --ignore-not-found >/dev/null 2>&1 || true
}

case "${1:-up}" in
test) e2e ;;
*) "${1:-up}" ;;
esac
