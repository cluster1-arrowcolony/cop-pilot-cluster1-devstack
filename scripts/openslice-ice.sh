#!/usr/bin/env bash
# OPENSLICE=ice: attach this cluster to the shared Cluster 1 OpenSlice at RISE ICE.
#
# OpenSlice reaches clusters only through CRIDGE, and CRIDGE talks to OpenSlice only over its
# Artemis broker. So instead of letting ICE into this machine, we run a CRIDGE here that dials
# out to the broker. OSOM sends every CR request to all CRIDGEs on the queue and the one whose
# cluster matches answers (the others reply "SEE OTHER"), so several clusters can share ICE.
#
# The broker is reached through OSL_ICE_TRANSPORT:
#   ziti    an OpenZiti service, using an identity from the COP-PILOT Ziti admins (partners)
#   ssh     an SSH tunnel to the OpenSlice VM (for those with an account on it)
#   direct  OSL_ICE_BROKER as given, e.g. on a VPN
source "$(dirname "$0")/lib.sh"
source "$ROOT/scripts/cridge-access.sh"
need kubectl jq curl docker k3d

NS=openslice-bridge
: "${OSL_ICE_TRANSPORT:=ziti}"
: "${OSL_ICE_BROKER:=}"                        # direct: tcp://host:port
: "${OSL_ICE_ZITI_IDENTITY:=}"                 # ziti: path to an enrolled identity JSON
: "${OSL_ICE_ZITI_SERVICE:=openslice-cluster1-ice-artemis}"
: "${OSL_ICE_SSH:=}"                         # ssh: user@host of the OpenSlice VM
: "${OSL_ICE_SSH_KEY:=$HOME/.ssh/id_ed25519}"  # ssh: key for that account
: "${OSL_ICE_SSH_KNOWN_HOSTS:=$HOME/.ssh/known_hosts}" # ssh: holds the VM's host key
: "${OSL_BROKER_USER:=}"
: "${OSL_BROKER_PASSWORD:=}"
: "${OSL_USER:=}"                              # OpenSlice account, for 'make test'
: "${OSL_PASSWORD:=}"

# The broker endpoint as seen from the CRIDGE pod.
broker_url() {
	case "$OSL_ICE_TRANSPORT" in
	ziti | ssh) echo "tcp://broker.$NS.svc.cluster.local:61616" ;;
	direct)
		[[ -n "$OSL_ICE_BROKER" ]] || die "OSL_ICE_TRANSPORT=direct needs OSL_ICE_BROKER=tcp://host:port"
		echo "$OSL_ICE_BROKER"
		;;
	*) die "OSL_ICE_TRANSPORT must be ziti, ssh or direct (got '$OSL_ICE_TRANSPORT')" ;;
	esac
}

# A Service "broker" in front of a pod that forwards to the ICE broker.
tunnel() {
	case "$OSL_ICE_TRANSPORT" in
	ziti)
		[[ -f "$OSL_ICE_ZITI_IDENTITY" ]] ||
			die "OSL_ICE_ZITI_IDENTITY must point to an enrolled Ziti identity JSON (see README)"
		kubectl -n "$NS" create secret generic ziti-identity --from-file=identity.json="$OSL_ICE_ZITI_IDENTITY" \
			--dry-run=client -o yaml | quiet kubectl apply -f -
		tunnel_pod "$ZITI_IMAGE" ziti-identity /id \
			'["ziti", "tunnel", "proxy", "--identity", "/id/identity.json", "'"$OSL_ICE_ZITI_SERVICE"':61616"]'
		;;
	ssh)
		ssh_tunnel
		;;
	direct) ;;
	esac
}

# ssh_tunnel: forward the broker port over SSH to the OpenSlice VM. The VM's host key comes from
# known_hosts, where the user's own first login recorded it, rather than from a scan at deploy
# time, which would trust whatever answers. The SSH client is built into a local image once, so
# the pod neither needs a package mirror nor gets a different client on each restart.
ssh_tunnel() {
	local host="${OSL_ICE_SSH#*@}" known image
	need ssh-keygen
	[[ -n "$OSL_ICE_SSH" ]] || die "OSL_ICE_TRANSPORT=ssh needs OSL_ICE_SSH=<user>@<host> of the OpenSlice VM"
	[[ -f "$OSL_ICE_SSH_KEY" ]] || die "OSL_ICE_SSH_KEY ($OSL_ICE_SSH_KEY) not found"
	ssh-keygen -y -P '' -f "$OSL_ICE_SSH_KEY" >/dev/null 2>&1 ||
		die "OSL_ICE_SSH_KEY ($OSL_ICE_SSH_KEY) is not a private key without a passphrase, which the tunnel pod needs"
	known="$(ssh-keygen -F "$host" -f "$OSL_ICE_SSH_KNOWN_HOSTS" 2>/dev/null | grep -v '^#' || true)"
	[[ -n "$known" ]] ||
		die "no host key for $host in $OSL_ICE_SSH_KNOWN_HOSTS; log in once with 'ssh $OSL_ICE_SSH', checking the fingerprint with the ICE admins"
	kubectl -n "$NS" create secret generic ssh-key --from-file=id="$OSL_ICE_SSH_KEY" \
		--from-literal=known_hosts="$known" \
		--dry-run=client -o yaml | quiet kubectl apply -f -

	image="devstack-ssh-tunnel:${SSH_TUNNEL_IMAGE//[:\/]/-}"
	if ! docker image inspect "$image" >/dev/null 2>&1; then
		info "building $image"
		printf 'FROM %s\nRUN apk add --no-cache openssh-client\n' "$SSH_TUNNEL_IMAGE" | quiet docker build -t "$image" -
	fi
	quiet k3d image import "$image" --cluster "$CLUSTER_NAME"

	tunnel_pod "$image" ssh-key /ssh \
		'["sh", "-c", "install -m 600 /ssh/id /tmp/id && exec ssh -N -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/ssh/known_hosts -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes -i /tmp/id -L 0.0.0.0:61616:127.0.0.1:61616 '"$OSL_ICE_SSH"'"]'
}

# secret_hash <name>: changes whenever that Secret's data does. Running pods never see a changed
# Secret (the processes read it once, and subPath mounts are not even refreshed), so the hash
# goes into the pod template to roll the Deployment when credentials change.
secret_hash() {
	kubectl -n "$NS" get secret "$1" -o jsonpath='{.data}' | cksum | cut -d' ' -f1
}

# tunnel_pod <image> <secret> <mount> <command-json>
tunnel_pod() {
	local hash
	hash="$(secret_hash "$2")"
	kubectl apply -f - >/dev/null <<-YAML
		apiVersion: apps/v1
		kind: Deployment
		metadata:
		  name: broker-tunnel
		  namespace: $NS
		spec:
		  replicas: 1
		  selector:
		    matchLabels: {app: broker-tunnel}
		  template:
		    metadata:
		      labels: {app: broker-tunnel}
		      annotations:
		        devstack/secret: "$hash"
		    spec:
		      containers:
		        - name: tunnel
		          image: $1
		          imagePullPolicy: IfNotPresent
		          command: $4
		          ports: [{containerPort: 61616}]
		          readinessProbe:
		            tcpSocket: {port: 61616}
		            periodSeconds: 5
		          volumeMounts: [{name: secret, mountPath: $3, readOnly: true}]
		      volumes: [{name: secret, secret: {secretName: $2}}]
		---
		apiVersion: v1
		kind: Service
		metadata:
		  name: broker
		  namespace: $NS
		spec:
		  selector: {app: broker-tunnel}
		  ports: [{port: 61616}]
	YAML
	quiet kubectl -n "$NS" rollout status deployment broker-tunnel --timeout 180s
}

cridge() {
	local broker hash kubeconfig
	broker="$(broker_url)"
	kubeconfig="$(cridge_kubeconfig)"
	kubectl -n "$NS" create secret generic cridge \
		--from-file=config="$kubeconfig" \
		--from-literal=spring.activemq.user="$OSL_BROKER_USER" \
		--from-literal=spring.activemq.password="$OSL_BROKER_PASSWORD" \
		--dry-run=client -o yaml | quiet kubectl apply -f -
	hash="$(secret_hash cridge)"
	kubectl apply -f - >/dev/null <<-YAML
		apiVersion: apps/v1
		kind: Deployment
		metadata:
		  name: cridge
		  namespace: $NS
		spec:
		  replicas: 1
		  selector:
		    matchLabels: {app: cridge}
		  template:
		    metadata:
		      labels: {app: cridge}
		      annotations:
		        devstack/broker: "$broker"
		        devstack/resources: "$CRIDGE_RESOURCES"
		        devstack/secret: "$hash"
		    spec:
		      containers:
		        - name: cridge
		          image: $OPENSLICE_REGISTRY/org.etsi.osl.cridge:$OPENSLICE_REF
		          env:
		            - name: SPRING_APPLICATION_JSON
		              value: >-
		                {"spring.config.import": "configtree:/etc/config/",
		                 "spring.activemq.brokerUrl": "$broker?jms.watchTopicAdvisories=false",
		                 "logging.level.org.etsi.osl.cridge": "INFO"}
		          volumeMounts:
		            - {name: cridge, mountPath: /root/.kube/config, subPath: config, readOnly: true}
		            - {name: cridge, mountPath: /etc/config/spring.activemq.user, subPath: spring.activemq.user, readOnly: true}
		            - {name: cridge, mountPath: /etc/config/spring.activemq.password, subPath: spring.activemq.password, readOnly: true}
		      volumes: [{name: cridge, secret: {secretName: cridge}}]
	YAML
	quiet kubectl -n "$NS" rollout status deployment cridge --timeout 300s
}

# CRIDGE logs "Cannot retrieve ..." when it starts before the remote catalog answers; it then
# never registers the cluster, so wait for the registration line and restart once if needed.
wait_registered() {
	registered() { kubectl -n "$NS" logs deployment/cridge 2>/dev/null | grep -q "will createOrUpdateResourceByNameVersion"; }
	failed() { kubectl -n "$NS" logs deployment/cridge 2>/dev/null | grep -q "Cannot retrieve KubernetesContextDefinition"; }
	no_broker() { kubectl -n "$NS" logs deployment/cridge 2>/dev/null | grep -q "Could not refresh JMS Connection"; }
	local deadline=$((SECONDS + 180))
	until registered; do
		if no_broker; then
			die "CRIDGE cannot reach the broker at $(broker_url) via $OSL_ICE_TRANSPORT; check the tunnel and OSL_BROKER_USER/OSL_BROKER_PASSWORD"
		fi
		if failed; then
			warn "CRIDGE could not reach the OpenSlice catalog; restarting it once"
			quiet kubectl -n "$NS" rollout restart deployment cridge
			quiet kubectl -n "$NS" rollout status deployment cridge --timeout 300s
		fi
		((SECONDS < deadline)) || die "CRIDGE did not register this cluster; see: kubectl -n $NS logs deploy/cridge"
		sleep 5
	done
}

up() {
	[[ -n "$OSL_BROKER_USER" && -n "$OSL_BROKER_PASSWORD" ]] ||
		die "set OSL_BROKER_USER and OSL_BROKER_PASSWORD in devstack.env (ask the ICE OpenSlice admins)"
	kubectl create namespace "$NS" --dry-run=client -o yaml | quiet kubectl apply -f -
	info "connecting to ICE OpenSlice broker via $OSL_ICE_TRANSPORT"
	tunnel
	cridge
	wait_registered
	ok "cluster registered in OpenSlice as k3d-$CLUSTER_NAME@https://$COLONIES_NODE_HOST:6443/"
}

e2e() {
	[[ -n "$OSL_ICE_URL" ]] || die "set OSL_ICE_URL (the ICE OpenSlice's URL) to run the test"
	[[ -n "$OSL_USER" && -n "$OSL_PASSWORD" ]] || die "set OSL_USER and OSL_PASSWORD (your ICE OpenSlice account) to run the test"
	OSL_URL="$OSL_ICE_URL" OSL_USER="$OSL_USER" OSL_PASSWORD="$OSL_PASSWORD" "$ROOT/scripts/test-openslice.sh"
}

down() {
	kubectl delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

case "${1:-up}" in
test) e2e ;;
*) "${1:-up}" ;;
esac
