#!/usr/bin/env bash
# Run the ColonyOS docker-reconciler next to the cluster. It and the executors it spawns
# share the k3d Docker network, so they all reach ColonyOS at the server node's NodePort.
source "$(dirname "$0")/lib.sh"
need docker

NAME="$RECONCILER_CONTAINER"
EXECUTOR_NAME="docker-reconciler-$LOCATION_NAME"

# running: the container runs and has not been restarted since it was created.
running() { [[ "$(docker inspect -f '{{.State.Running}} {{.RestartCount}}' "$NAME" 2>/dev/null)" == "true 0" ]]; }

up() {
	load_identities
	local envfile="$STATE/reconciler.env"
	(
		umask 077
		cat >"$envfile" <<-EOF2
			COLONIES_SERVER_HOST=$COLONIES_NODE_HOST
			COLONIES_SERVER_PORT=$COLONIES_NODEPORT
			COLONIES_TLS=false
			COLONIES_COLONY_NAME=$COLONY_NAME
			COLONIES_COLONY_PRVKEY=$COLONIES_COLONY_PRVKEY
			COLONIES_EXECUTOR_NAME=$EXECUTOR_NAME
			COLONIES_EXECUTOR_TYPE=docker-reconciler
			COLONIES_EXECUTOR_LOCATION=$LOCATION_NAME
			EXECUTOR_LOCATION_NAME=$LOCATION_NAME
			DOCKER_NETWORK=$DOCKER_NETWORK
			EXECUTOR_HW_PLATFORM=linux
			EXECUTOR_HW_ARCHITECTURE=$(docker info --format '{{.Architecture}}' | sed 's/x86_64/amd64/; s/aarch64/arm64/')
		EOF2
	)
	# Recreate so env changes always take effect.
	docker rm -f "$NAME" >/dev/null 2>&1 || true
	info "starting $DOCKER_RECONCILER_IMAGE as $EXECUTOR_NAME"
	quiet docker run -d --name "$NAME" --restart unless-stopped \
		--network "$DOCKER_NETWORK" \
		-v /var/run/docker.sock:/var/run/docker.sock \
		--env-file "$envfile" \
		"$DOCKER_RECONCILER_IMAGE"

	# With the colony key the reconciler registers and approves itself, and the executors it spawns.
	# The executor list keeps the old registration across restarts, so judge the new container by
	# its own log, which only covers this run: it logs this line once it has registered.
	local deadline=$((SECONDS + 90))
	until docker logs "$NAME" 2>&1 | grep -q 'Deployment Controller Executor started'; do
		running || die "$NAME stopped or restarted during startup; see: docker logs $NAME"
		((SECONDS < deadline)) || die "timed out waiting for $EXECUTOR_NAME to register; see: docker logs $NAME"
		sleep 2
	done
	running || die "$NAME stopped or restarted after registering; see: docker logs $NAME"
	ok "reconciler $EXECUTOR_NAME registered for location $LOCATION_NAME"
}

down() {
	docker rm -f "$NAME" >/dev/null 2>&1 || true
}

"${1:-up}"
