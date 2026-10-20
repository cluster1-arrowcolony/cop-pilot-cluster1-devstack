#!/usr/bin/env bash
# Create or delete the k3d cluster that hosts ColonyOS and Kolony.
source "$(dirname "$0")/lib.sh"
need k3d kubectl docker

# Where apiserver/ (the API server's authorization config) is mounted in the k3d server.
APISERVER_DIR=/etc/devstack/apiserver

up() {
	local cache=()
	[[ "$IMAGE_CACHE" == on || "$IMAGE_CACHE" == off ]] || die "IMAGE_CACHE must be on or off (got '$IMAGE_CACHE')"
	if [[ "$IMAGE_CACHE" == on ]]; then
		"$ROOT/scripts/cache.sh" up
	fi
	if k3d cluster list "$CLUSTER_NAME" >/dev/null 2>&1; then
		ok "cluster $CLUSTER_NAME exists"
		k3d cluster start "$CLUSTER_NAME" >/dev/null
		if [[ "$IMAGE_CACHE" == on ]]; then
			if docker exec "$COLONIES_NODE_HOST" grep -q devstack-cache /etc/rancher/k3s/registries.yaml 2>/dev/null; then
				"$ROOT/scripts/cache.sh" connect "$DOCKER_NETWORK"
			else
				info "cluster $CLUSTER_NAME was created without the image cache; 'make down' and 'make up' to use it"
			fi
		fi
		# k3d fixes the published ports when it creates the cluster.
		check_port 6443 "127.0.0.1:$API_HOST_PORT" API_HOST_PORT
		check_port "$COLONIES_NODEPORT" "127.0.0.1:$COLONIES_HOST_PORT" COLONIES_HOST_PORT
		check_port "$OPENSLICE_NODEPORT" "$OPENSLICE_BIND:$OPENSLICE_HOST_PORT" "OPENSLICE_URL/OPENSLICE_BIND"
		if ! docker exec "$COLONIES_NODE_HOST" test -f "$APISERVER_DIR/authorization.yaml" 2>/dev/null; then
			warn "cluster $CLUSTER_NAME was created without apiserver/authorization.yaml, so CRIDGE can read every Secret; 'make down' and 'make up' to fix"
		fi
	else
		info "creating k3d cluster $CLUSTER_NAME ($K3S_IMAGE)"
		if [[ "$IMAGE_CACHE" == on ]]; then
			# The caches must be on the cluster's network before k3s pulls its first images, so
			# create the network here; k3d then uses it, and down() removes it.
			docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1 ||
				quiet docker network create "$DOCKER_NETWORK"
			"$ROOT/scripts/cache.sh" connect "$DOCKER_NETWORK"
			"$ROOT/scripts/cache.sh" registries "$STATE/registries.yaml"
			cache=(--registry-config "$STATE/registries.yaml")
		fi
		# Traefik and servicelb are disabled to keep the cluster small, and because CRIDGE
		# would register every CRD they bring into the OpenSlice catalog.
		k3d cluster create "$CLUSTER_NAME" \
			--image "$K3S_IMAGE" \
			--servers 1 --agents 0 --no-lb \
			--api-port "127.0.0.1:$API_HOST_PORT" \
			--port "127.0.0.1:$COLONIES_HOST_PORT:$COLONIES_NODEPORT@server:0:direct" \
			--port "$OPENSLICE_BIND:$OPENSLICE_HOST_PORT:$OPENSLICE_NODEPORT@server:0:direct" \
			--k3s-arg "--disable=traefik@server:0" \
			--k3s-arg "--disable=servicelb@server:0" \
			--k3s-arg "--tls-san=$COLONIES_NODE_HOST@server:0" \
			--volume "$ROOT/apiserver:$APISERVER_DIR:ro@server:0" \
			--k3s-arg "--kube-apiserver-arg=authorization-config=$APISERVER_DIR/authorization.yaml@server:0" \
			--kubeconfig-update-default=false \
			${cache[@]+"${cache[@]}"} \
			--wait
	fi
	k3d kubeconfig get "$CLUSTER_NAME" >"$KUBECONFIG"
	chmod 600 "$KUBECONFIG"
	# Same cluster, addressed from containers on the k3d network (CRIDGE, reconciler).
	sed "s#server: https://.*#server: https://$COLONIES_NODE_HOST:6443#" "$KUBECONFIG" >"$STATE/kubeconfig.internal"
	chmod 600 "$STATE/kubeconfig.internal"
	retry 120 "Kubernetes API" kubectl get --raw /readyz
	ok "cluster $CLUSTER_NAME ready; export KUBECONFIG=$KUBECONFIG"
}

down() {
	# Executors spawned by the reconciler live outside the cluster but on its network.
	local ids id
	ids="$(docker ps -aq --filter "network=$DOCKER_NETWORK" --filter "label=colonies.deployment" 2>/dev/null || true)"
	ids+=" $(docker ps -aq --filter "name=^devstack-$CLUSTER_NAME-" 2>/dev/null || true)"
	if [[ -n "${ids// /}" ]]; then
		# shellcheck disable=SC2086
		docker rm -f $ids >/dev/null
	fi
	# The image caches outlive the cluster; detach them so its network can go.
	ids="$(docker ps -aq --filter "network=$DOCKER_NETWORK" --filter "label=devstack.cache" 2>/dev/null || true)"
	for id in $ids; do
		docker network disconnect -f "$DOCKER_NETWORK" "$id" >/dev/null 2>&1 || true
	done
	if k3d cluster list "$CLUSTER_NAME" >/dev/null 2>&1; then
		info "deleting k3d cluster $CLUSTER_NAME"
		k3d cluster delete "$CLUSTER_NAME"
	fi
	# k3d leaves a network it did not create itself, as with the image cache.
	docker network rm "$DOCKER_NETWORK" >/dev/null 2>&1 || true
	rm -f "$KUBECONFIG" "$STATE/kubeconfig.internal" "$STATE/kubeconfig.cridge"
}

"${1:-up}"
