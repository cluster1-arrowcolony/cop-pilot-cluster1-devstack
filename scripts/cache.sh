#!/usr/bin/env bash
# Pull-through caches for the registries the cluster pulls its images from. They run as plain
# containers beside the cluster, shared by every devstack on this machine, and keep their data
# in Docker volumes, so a new cluster after 'make down' does not download everything again
# (OPENSLICE=local alone is about 5 GB). k3s uses them as registry mirrors and falls back to
# the registry itself when a cache does not answer. Nothing is published on the host.
#
#   cache.sh up                  start the caches (IMAGE_CACHE=on)
#   cache.sh registries <file>   write the k3s registries config that points to them
#   cache.sh connect <network>   attach the caches to a cluster's Docker network
#   cache.sh down                remove the caches and their volumes ('make clean')
source "$(dirname "$0")/lib.sh"
need docker

# <registry> <upstream URL>, one cache per registry: a proxy serves a single upstream.
CACHES="docker.io https://registry-1.docker.io
quay.io https://quay.io
registry.k8s.io https://registry.k8s.io
labs.etsi.org:5050 https://labs.etsi.org:5050"

# name <registry>: the cache's container and volume name, a valid DNS label.
name() { echo "devstack-cache-$(echo "$1" | tr '.:' '--')"; }

up() {
	local registry url n config
	while read -r registry url; do
		n="$(name "$registry")"
		config="$REGISTRY_IMAGE $url"
		if [[ "$(docker inspect -f '{{index .Config.Labels "devstack.cache"}}' "$n" 2>/dev/null)" != "$config" ]]; then
			docker rm -f "$n" >/dev/null 2>&1 || true
			# TTL 0 keeps cached images until 'make clean' instead of the default of a week.
			quiet docker run -d --name "$n" --restart unless-stopped \
				--label "devstack.cache=$config" \
				-v "$n:/var/lib/registry" \
				-e REGISTRY_PROXY_REMOTEURL="$url" \
				-e REGISTRY_PROXY_TTL=0s \
				-e REGISTRY_LOG_LEVEL=warn \
				"$REGISTRY_IMAGE"
		fi
		quiet docker start "$n"
	done <<<"$CACHES"
	ok "image caches running for $(echo "$CACHES" | cut -d' ' -f1 | tr '\n' ' ')"
}

registries() {
	local registry url
	{
		echo "mirrors:"
		while read -r registry url; do
			echo "  \"$registry\":"
			echo "    endpoint: [\"http://$(name "$registry"):5000\"]"
		done <<<"$CACHES"
	} >"$1"
}

connect() {
	local registry url n
	while read -r registry url; do
		n="$(name "$registry")"
		if [[ "$(docker inspect -f "{{if index .NetworkSettings.Networks \"$1\"}}yes{{end}}" "$n")" != yes ]]; then
			quiet docker network connect "$1" "$n"
		fi
	done <<<"$CACHES"
}

down() {
	local registry url n
	while read -r registry url; do
		n="$(name "$registry")"
		docker rm -f "$n" >/dev/null 2>&1 || true
		docker volume rm "$n" >/dev/null 2>&1 || true
	done <<<"$CACHES"
}

case "${1:-up}" in
up) up ;;
registries) registries "$2" ;;
connect) connect "$2" ;;
down) down ;;
*) die "usage: cache.sh up|registries <file>|connect <network>|down" ;;
esac
