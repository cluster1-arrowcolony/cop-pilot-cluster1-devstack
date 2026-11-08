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

# --- Catalogue-as-code helpers (catalog/): bundles with characteristics, LCM rules, day-2 changes ---

# osl_cfss_chars <name> <rfss-id> <chars-json>: like osl_cfss, with serviceSpecCharacteristic
# given as a JSON array of {name, value, valueType}; each becomes a configurable characteristic
# with that default. Prints the new spec's id.
osl_cfss_chars() {
	jq -n --arg name "$1" --arg rfss "$2" --argjson chars "$3" '{
		name: $name, version: "0.1.0", lifecycleStatus: "Active", isBundle: true,
		"@type": "CustomerFacingServiceSpecification", type: "CustomerFacingServiceSpecification",
		description: "Created by cop-pilot-cluster1-devstack",
		serviceSpecRelationship: [{id: $rfss, relationshipType: "dependency", "@type": "ServiceSpecificationRef"}],
		serviceSpecCharacteristic: [$chars[] | {
			name: .name, configurable: true, valueType: (.valueType // "TEXT"),
			serviceSpecCharacteristicValue: [{value: {value: (.value|tostring), alias: ""}, valueType: (.valueType // "TEXT"), isDefault: true}]
		}]
	}' | { osl POST "/serviceCatalogManagement/v4/serviceSpecification" "$(cat)"; } | jq -er '.id // empty'
}

# osl_rule <name> <phase> <spec-id> <code-file>: create an LCM rule (PRE_PROVISION, CREATION,
# AFTER_ACTIVATION, SUPERVISION, AFTER_DEACTIVATION) whose exec() body is the file; prints its id.
osl_rule() {
	local name=$1 phase=$2 spec=$3 file=$4
	jq -n --arg name "$name" --arg phase "$phase" --arg spec "$spec" --rawfile code "$file" '{
		name: $name, description: ("Created by cop-pilot-cluster1-devstack: " + $name),
		lcmrulephase: $phase, lifecycleStatus: "Active", version: "0.1.0", content: "", code: $code,
		serviceSpecs: [{id: $spec, "@type": "ServiceSpecificationRef"}]
	}' >"$STATE/rule.json"
	osl POST "/lcmrulesmanagement/v1/lcmRuleSpecification" "@$STATE/rule.json" | jq -er '.id // empty'
}

# osl_service <id>: the service from the inventory.
osl_service() { osl GET "/serviceInventory/v4/service/$1"; }

# osl_service_char <id> <name>: one characteristic's value of a service, or empty.
osl_service_char() {
	osl_service "$1" | jq -r --arg n "$2" '[.serviceCharacteristic[]? | select(.name == $n)][0].value.value // empty'
}

# osl_patch_service_char <id> <name> <value>: change one characteristic of a running service,
# as the portal's "modify service" does. OpenSlice keeps the others.
osl_patch_service_char() {
	jq -n --arg n "$2" --arg v "$3" '{serviceCharacteristic: [{name: $n, value: {value: $v, alias: ""}, valueType: "TEXT"}]}' |
		{ osl PATCH "/serviceInventory/v4/service/$1" "$(cat)"; } >/dev/null
}

# osl_order_modify <service-id> <chars-json>: a service order with one "modify" item on a
# running service, carrying the characteristics given as a JSON array of {name, value}.
# The item repeats the service's specification and supporting services, as the portal does.
osl_order_modify() {
	local svc now later
	svc="$(osl_service "$1")" || return
	now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	later="$(date -u -d '+1 day' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+1d +%Y-%m-%dT%H:%M:%SZ)"
	# The inventory names the spec "serviceSpecification" (not the model's serviceSpecificationRef);
	# without its id the API answers 400 ("There is no Service Specification with Id: null").
	# The item itself is created ACKNOWLEDGED, as LCM rules' createServiceOrder does: OSOM's modify
	# delegate (ProcessOrderItemActionModify) acts only on items in that state, and a PATCH of the
	# order's state does not touch the items, so an INITIAL item completes without doing anything.
	# With all items acknowledged the API acknowledges the order itself; osl_ack is then a no-op.
	jq -n --argjson svc "$svc" --argjson chars "$2" --arg now "$now" --arg later "$later" '{
		description: "devstack modify order", requestedStartDate: $now, requestedCompletionDate: $later,
		orderItem: [{id: "1", action: "modify", state: "ACKNOWLEDGED",
			service: {id: $svc.id, name: $svc.name, state: "active",
				serviceSpecification: {id: $svc.serviceSpecification.id, name: $svc.serviceSpecification.name},
				supportingService: [($svc.supportingService // [])[] | {id, name, "@referredType"}],
				serviceCharacteristic: [$chars[] | {name: .name, value: {value: (.value|tostring), alias: ""}, valueType: "TEXT"}]}}]
	}' | { osl POST "/serviceOrdering/v4/serviceOrder" "$(cat)"; } | jq -er '.id // empty'
}

# osl_service_notes <id> [n]: the last n notes of a service, oldest first (what OSOM and the rules did).
osl_service_notes() {
	osl_service "$1" | jq -r --argjson n "${2:-8}" '[.note[]? | "\(.date) \(.author): \(.text)"] | .[-$n:] | .[]'
}

# --- Categories (TMF633): the catalogue structure a peer such as HypO reads ---

# osl_category <name> [description]: create a root service category (lifecycle Active); prints its id.
osl_category() {
	jq -n --arg n "$1" --arg d "${2:-Created by cop-pilot-cluster1-devstack}" \
		'{name: $n, description: $d, isRoot: true, lifecycleStatus: "Active", version: "1.0"}' |
		{ osl POST "/serviceCatalogManagement/v4/serviceCategory" "$(cat)"; } | jq -er '.id // empty'
}

# osl_catalog_add_category <catalog-id> <category-id>: add a category to a catalogue, keeping its others.
osl_catalog_add_category() {
	local cats
	cats="$(osl GET "/serviceCatalogManagement/v4/serviceCatalog/$1" | jq -c --arg c "$2" '[(.category // [])[] | {id}] + [{id: $c}] | unique_by(.id)')" || return
	osl PATCH "/serviceCatalogManagement/v4/serviceCatalog/$1" "$(jq -n --argjson c "$cats" '{category: $c}')" >/dev/null
}

# osl_candidate_of_spec <spec-id>: the id of the service candidate OpenSlice created for a spec.
osl_candidate_of_spec() {
	osl GET "/serviceCatalogManagement/v4/serviceCandidate" |
		jq -er --arg s "$1" '[.[] | select(.serviceSpecification.id == $s)][0].id // empty'
}

# osl_category_add_spec <category-id> <spec-id>: put a spec in a category (through its candidate;
# a candidate can be in several categories).
osl_category_add_spec() {
	local cand
	cand="$(osl_candidate_of_spec "$2")" || return
	osl PATCH "/serviceCatalogManagement/v4/serviceCandidate/$cand" "$(jq -n --arg c "$1" '{category: [{id: $c}]}')" >/dev/null
}

# osl_spec_lifecycle <spec-id> <status>: set a spec's lifecycleStatus ("In study", "In design",
# "In test", "Active", "Launched", "Retired", "Obsolete", "Rejected").
osl_spec_lifecycle() {
	osl PATCH "/serviceCatalogManagement/v4/serviceSpecification/$1" "$(jq -n --arg s "$2" '{lifecycleStatus: $s}')" >/dev/null
}

# osl_category_delete <category-id>: delete a category. OpenSlice refuses (HTTP 500) while the
# category is in a catalogue or still holds candidates, so it is detached and emptied first; the
# specs themselves stay.
osl_category_delete() {
	local cid=$1 cat keep
	for cat in $(osl GET "/serviceCatalogManagement/v4/serviceCatalog" | jq -r --arg c "$cid" '.[] | select(any(.category[]?; .id == $c)) | .id'); do
		keep="$(osl GET "/serviceCatalogManagement/v4/serviceCatalog/$cat" | jq -c --arg c "$cid" '[.category[]? | select(.id != $c) | {id}]')" || return
		osl PATCH "/serviceCatalogManagement/v4/serviceCatalog/$cat" "$(jq -n --argjson c "$keep" '{category: $c}')" >/dev/null || return
	done
	osl PATCH "/serviceCatalogManagement/v4/serviceCategory/$cid" '{"serviceCandidate": []}' >/dev/null || return
	osl DELETE "/serviceCatalogManagement/v4/serviceCategory/$cid" >/dev/null
}
