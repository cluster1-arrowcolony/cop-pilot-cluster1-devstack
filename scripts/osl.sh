# OpenSlice TMF API helpers. Source after lib.sh; set OSL_URL, OSL_USER and OSL_PASSWORD first.
# shellcheck shell=bash

TMF=/tmf-api

osl_login() {
	OSL_TOKEN="$(curl -sf "$OSL_URL/auth/realms/openslice/protocol/openid-connect/token" \
		-d grant_type=password -d client_id=osapiWebClientId \
		--data-urlencode "username=$OSL_USER" --data-urlencode "password=$OSL_PASSWORD" |
		jq -er '.access_token // empty')" || die "OpenSlice login as $OSL_USER at $OSL_URL failed"
}

# osl <METHOD> <path under /tmf-api> [json-body]
# A body of @<file> is read from that file, for bodies larger than an argument may be (Linux
# limits one to 128 KiB).
osl() {
	local method=$1 path=$2 body=${3:-}
	local args=(-sS --fail-with-body -X "$method" -H "Authorization: Bearer $OSL_TOKEN" -H "Accept: application/json")
	[[ -n "$body" ]] && args+=(-H "Content-Type: application/json" --data-binary "$body")
	curl "${args[@]}" "$OSL_URL$TMF$path"
}

# osl_resource_spec <name>: print the resource specification with that exact name.
osl_resource_spec() {
	osl GET "/resourceCatalogManagement/v4/resourceSpecification" |
		jq -ce --arg n "$1" '[.[] | select(.name == $n)][0] // empty' ||
		die "no resource specification named $1 (is CRIDGE connected to this cluster?)"
}

# osl_cr_rfss <name> <crd-resource-spec-name> <cr-yaml> <check-field> <available-value>
# Create a resource-facing service spec that deploys <cr-yaml> through CRIDGE, the way the
# OpenSlice UI does from a CRD resource spec, and print its id.
# Callers run it inside $(...), where bash 3.2 ignores set -e, so each step checks its own status.
osl_cr_rfss() {
	local name=$1 rspec_name=$2 cr=$3 field=$4 avail=$5 rspec
	rspec="$(osl_resource_spec "$rspec_name")" || return
	rspec="$(osl GET "/resourceCatalogManagement/v4/resourceSpecification/$(jq -r .id <<<"$rspec")")" || return
	# The resource spec goes in on stdin: a CRD's can be larger than an argument may be.
	jq --arg name "$name" --arg cr "$cr" --arg field "$field" --arg avail "$avail" '
		. as $rs |
		def val($v): [{value: {value: $v, alias: ""}, valueType: "TEXT", isDefault: true}];
		def override: {_CR_SPEC: $cr, _CR_CHECK_FIELD: $field, _CR_CHECKVAL_AVAILABLE: $avail};
		{
			name: $name, version: "0.1.0", lifecycleStatus: "Active",
			"@type": "ResourceFacingServiceSpecification", type: "ResourceFacingServiceSpecification",
			description: "Created by cop-pilot-cluster1-devstack",
			resourceSpecification: [{id: $rs.id, name: $rs.name, "@type": $rs["@type"]}],
			serviceSpecCharacteristic: [
				$rs.resourceSpecCharacteristic[] | {
					name, description, configurable: false,
					valueType: (.valueType // "TEXT"),
					serviceSpecCharacteristicValue: (
						if override[.name] then val(override[.name])
						else [(.resourceSpecCharacteristicValue // [])[] | {value, valueType, isDefault}]
						end)
				}
			]
		}' <<<"$rspec" >"$STATE/rfss.json" || return
	osl POST "/serviceCatalogManagement/v4/serviceSpecification" "@$STATE/rfss.json" | jq -er '.id // empty'
}

# osl_cfss <name> <rfss-id>: customer-facing spec that wraps one RFSS; prints its id.
# It must be a bundle: OSOM leaves any other CFSS "reserved" for a provider to start by hand.
osl_cfss() {
	jq -n --arg name "$1" --arg rfss "$2" '{
		name: $name, version: "0.1.0", lifecycleStatus: "Active", isBundle: true,
		"@type": "CustomerFacingServiceSpecification", type: "CustomerFacingServiceSpecification",
		description: "Created by cop-pilot-cluster1-devstack",
		serviceSpecRelationship: [{id: $rfss, relationshipType: "dependency", "@type": "ServiceSpecificationRef"}]
	}' | { osl POST "/serviceCatalogManagement/v4/serviceSpecification" "$(cat)"; } | jq -er '.id // empty'
}

# osl_order <cfss-id> <cfss-name>: place a service order and print its id.
osl_order() {
	local now later
	now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	later="$(date -u -d '+1 day' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+1d +%Y-%m-%dT%H:%M:%SZ)"
	jq -n --arg id "$1" --arg name "$2" --arg now "$now" --arg later "$later" '{
		description: "devstack test order", requestedStartDate: $now, requestedCompletionDate: $later,
		orderItem: [{id: "1", action: "add",
			service: {name: $name, serviceSpecification: {id: $id, name: $name}, serviceCharacteristic: []}}]
	}' | { osl POST "/serviceOrdering/v4/serviceOrder" "$(cat)"; } | jq -er '.id // empty'
}

# osl_ack <order-id>: acknowledge an order so OSOM starts it. (OSL_AUTOACK_ORDER is only
# honoured for internal sessions, not for API clients with a token.)
osl_ack() {
	osl PATCH "/serviceOrdering/v4/serviceOrder/$1" '{"state":"ACKNOWLEDGED"}' >/dev/null
}

# osl_terminate <tag>: end the live services whose names start with "<tag> ", as a test's do.
osl_terminate() {
	local svcs svc
	svcs="$(osl GET "/serviceInventory/v4/service" |
		jq -r --arg t "$1 " '.[] | select((.name | startswith($t)) and .state != "terminated") | .id')" || return
	for svc in $svcs; do
		osl PATCH "/serviceInventory/v4/service/$svc" '{"state":"terminated"}' >/dev/null || return
	done
}
