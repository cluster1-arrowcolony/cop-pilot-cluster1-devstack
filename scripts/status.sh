#!/usr/bin/env bash
# Show what is running and how to reach it.
source "$(dirname "$0")/lib.sh"

echo "cluster   $CLUSTER_NAME  (OPENSLICE=$OPENSLICE)"
if ! k3d cluster list "$CLUSTER_NAME" >/dev/null 2>&1; then
	echo "          not created; run 'make up'"
	exit 0
fi
echo "k8s API   https://127.0.0.1:$API_HOST_PORT   export KUBECONFIG=$KUBECONFIG"
echo "ColonyOS  http://localhost:$COLONIES_HOST_PORT  source .devstack/colonies.env"
if [[ "$OPENSLICE" == local ]]; then
	echo "OpenSlice $OPENSLICE_URL  (published at $OPENSLICE_BIND:$OPENSLICE_HOST_PORT)"
fi
echo
kubectl get pods -n colonyos -o wide --no-headers 2>/dev/null | awk '{print "  colonyos/" $1, $3}'
kubectl get pods -n kolony --no-headers 2>/dev/null | awk '{print "  kolony/" $1, $3}'
kubectl get blueprintdefinitions -A --no-headers 2>/dev/null | awk '{print "  definition " $2 " (" $3 ") registered=" $5}'
docker ps --filter "network=$DOCKER_NETWORK" --format '  docker/{{.Names}} {{.Status}}' | grep -v "k3d-$CLUSTER_NAME-" || true
if [[ -f "$IDENTITIES" ]]; then
	colonies_cli_env
	echo
	colonies executor ls 2>/dev/null || warn "ColonyOS not reachable on localhost:$COLONIES_HOST_PORT"
fi
