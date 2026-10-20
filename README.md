# COP-PILOT Cluster 1 devstack

A one-command development environment for the COP-PILOT (Grant Agreement 101189819) Cluster 1
stack: **ColonyOS** and the **Kolony** operator on a local Kubernetes cluster, optionally driven by
**ETSI OpenSlice**, either a local instance or the shared Cluster 1 instance at RISE ICE.

```
             OpenSlice (local, or ICE)  -- service order -+
                                                          | Artemis (JMS)
  +- k3d cluster -----------------------------------------v--------------+
  |  CRIDGE -- creates Blueprint CRs in the order's namespace            |
  |  Kolony -- syncs Blueprints/BlueprintDefinitions/ColonyProcesses --+ |
  |  ColonyOS server + TimescaleDB  <----------------------------------+ |
  +----------------------------^-----------------------------------------+
                               | k3d Docker network
  docker-reconciler -- starts executor containers for Blueprints at its location
```

## Requirements

- Docker: Linux, macOS (Docker Desktop, OrbStack, Colima) or Windows with WSL2.
- `bash`, `make`, `curl`, `jq`, `git`, `openssl`.
- About 4 CPUs and 4 GB RAM free for the core stack; another 8 GB for `OPENSLICE=local`.
- Free local ports 6550, 50080 and 8090 (configurable, see below).

`make tools` downloads pinned copies of k3d, kubectl, helm and the colonies CLI into
`.devstack/bin`, so nothing else has to be installed. It checks each download against
`checksums.txt` and stops on a mismatch.

If Docker is installed as a snap (Ubuntu), keep this checkout under your home directory. Snap
Docker cannot read files under `/tmp`.

## Quick start

```bash
cp devstack.env.example devstack.env   # optional; set CLUSTER_NAME at least if you use ICE
make up                                # about a minute; ColonyOS + Kolony + reconciler
make test                              # Blueprint -> executor -> function call, ~20 s
source .devstack/colonies.env          # colonies CLI and kubectl against the devstack
colonies executor ls
kubectl get blueprints -A
```

`make down` deletes the cluster and containers, and with them everything stored in the cluster,
such as a local OpenSlice's catalog. It keeps your keys, so the next `make up` comes back with the
same colony. It also keeps the image caches (see below), so the new cluster does
not download its images again. `make clean` removes everything, including keys, tools and the
caches.

## OpenSlice modes

Set `OPENSLICE` in `devstack.env`, or on the command line: `make up OPENSLICE=local`.

| Mode | What you get |
|---|---|
| `none` (default) | ColonyOS and Kolony only. Apply Blueprint CRs yourself. |
| `local` | OpenSlice 2025Q4 in the same cluster at **http://openslice.localhost:8090** (or `OPENSLICE_URL`), with CRIDGE managing this cluster. |
| `ice` | This cluster is attached to the shared Cluster 1 OpenSlice at RISE ICE. |

### `local`

The first `make up` pulls about 5 GB of images and takes a few minutes. Log in to the portal as
`devstack`; the password is `OPENSLICE_PASSWORD` in `.devstack/identities.env`. Browsers and curl
resolve `*.localhost` to your machine without any DNS setup.

The OpenSlice chart's own passwords are public, including Keycloak's admin password, and the
portal's URL also serves Keycloak's admin console (`/auth/admin`). So the devstack generates
OpenSlice's passwords too and keeps them in `identities.env`: `OPENSLICE_KEYCLOAK_ADMIN_PASSWORD`
for the Keycloak user `admin`, and `OPENSLICE_BROKER_PASSWORD` and `OPENSLICE_DB_*` for the
broker and MySQL. An OpenSlice installed by an earlier version of the devstack keeps the chart's
passwords, and `make up` warns about it until it is recreated with `make down` and `make up`.

`make test` then also places a real service order. It creates an RFSS from the Blueprint CRD,
wraps it in a bundled CFSS, orders and acknowledges it, and waits for the Blueprint CR in the
order's namespace, the executor and the completed order. Then it terminates the service and
checks that everything is removed.

#### Making a local OpenSlice reachable to peers (SIF, HypO)

An OpenSlice of your own can join the COP-PILOT platform: the Secure Integration Fabric (SIF,
OpenZiti) exposes it to the end-to-end orchestrator, which is then peered with it. That works
only if every client uses the one URL OpenSlice is configured with. Keycloak names a token's
issuer after the address it was requested at, and the OpenSlice services reject tokens issued at
any other address, so a peer using another URL logs in but gets HTTP 401 on every call.

Set that URL with `OPENSLICE_URL` in `devstack.env`:

| Setting | Default | Meaning |
|---|---|---|
| `OPENSLICE_URL` | `http://openslice.localhost:8090` | the URL of the portal and APIs, for browsers, peers and the pods |
| `OPENSLICE_BIND` | the URL's address if it is an IPv4 address, else `127.0.0.1` | the host address the port is published on |

The port comes from the URL (80 when it names none); `OPENSLICE_HOST_PORT` is the older way to
set only the port. k3d fixes published ports when it creates the cluster, so a new port or
address needs `make down` and `make up`; a new host name only `make openslice`. The pods reach an
IP address through the host and a host name through a DNS rewrite to the ingress; on the host, a
host name other than `*.localhost` must resolve to `OPENSLICE_BIND`.

Run the Ziti tunneler on the machine that runs the devstack, and give the peering the same URL.
The Ziti service has two addresses: the one peers dial (its intercept address) and the one your
tunneler forwards to (its host address). Prefer a Ziti host name for the first and loopback for
the second, so that OpenSlice is reachable only through SIF:

```bash
# devstack.env; the Ziti service intercepts osl-yourorg.ziti:80 and forwards to 127.0.0.1:80
OPENSLICE_URL=http://osl-yourorg.ziti
OPENSLICE_BIND=127.0.0.1
```

and add `127.0.0.1 osl-yourorg.ziti` to `/etc/hosts`, so the devstack's own calls reach it too.

The SIF service-creation pipeline currently uses one address, `SERVICE_IP:SERVICE_PORT`, for both,
so ask the platform team to create the service with a separate intercept address. If you use the
pipeline as it is, `OPENSLICE_URL=http://<SERVICE_IP>:<SERVICE_PORT>` works too, but then
OpenSlice is published on that address, over plain HTTP, to everyone who can reach it: Docker's
port rules bypass host firewalls such as ufw, and `make up` warns about it. Block the port in
front of the host, or bind to an address that only the host reaches.

`make peering-check` then does what a peer does, from your host: it checks that OpenSlice runs
with `OPENSLICE_URL`, that Keycloak issues tokens there, logs in with a password grant on the
`osapiWebClientId` client and reads the service catalog. It logs in as `devstack` unless you set
`OSL_USER` and `OSL_PASSWORD` to the account the peer will get. Peers list only
customer-facing service specifications.

Joining, step by step:

1. Run `make up` and `make test` with the `OPENSLICE_URL` you will keep. `make test` briefly puts
   a test service specification in the catalog, so run it before the peering.
2. On the same Linux host (the Ziti tunneler needs Linux and sudo), enroll the Ziti identity you
   get from the platform team and have them create the Ziti service for your URL, both with the
   platform's integration pipelines.
3. Create an account for the peer in Keycloak (realm `openslice`, admin password
   `OPENSLICE_KEYCLOAK_ADMIN_PASSWORD`) with as few roles as still let
   `make peering-check OSL_USER=<user> OSL_PASSWORD=<password>` pass. Don't hand out `devstack`,
   which has every role.
4. Have the peering done with your URL and that account.

Once peered, don't run `make down` or `make clean`: they delete the cluster and with it
OpenSlice's data, including the catalog the peer has read. Restarting the host is fine.

### `ice`

OpenSlice talks to clusters only through CRIDGE, and CRIDGE talks to OpenSlice only over its
Artemis broker. So instead of letting ICE into your machine, the devstack runs its own CRIDGE that
dials **out** to the ICE broker. OSOM sends each CR request to every CRIDGE and the one for the
matching cluster handles it, so many developers can share ICE. Your cluster shows up in the ICE
catalog as `k3d-<CLUSTER_NAME>@https://k3d-<CLUSTER_NAME>-server-0:6443/`, so **pick a unique
`CLUSTER_NAME`**.

Ask the ICE OpenSlice admins for:

- its URL (`OSL_ICE_URL`) and an OpenSlice account (`OSL_USER`, `OSL_PASSWORD`) for the portal,
  `make test` and `make retarget`;
- broker credentials (`OSL_BROKER_USER`, `OSL_BROKER_PASSWORD`);
- a way to reach the broker, set with `OSL_ICE_TRANSPORT`:

| Transport | For | Settings |
|---|---|---|
| `ziti` (default) | partners | `OSL_ICE_ZITI_IDENTITY=/path/to/enrolled-identity.json` (see below), `OSL_ICE_ZITI_SERVICE` (default `openslice-cluster1-ice-artemis`) |
| `ssh` | those with an account on the OpenSlice VM | `OSL_ICE_SSH=<user>@<host>`, `OSL_ICE_SSH_KEY=~/.ssh/<key>` (without a passphrase) |
| `direct` | VPN or other routed access | `OSL_ICE_BROKER=tcp://<host>:61616` |

With `ziti`, the Ziti admins give you a one-time enrollment token (a `.jwt` file) for an identity
that may dial the broker service. Enroll it with `make ziti-enroll JWT=<file.jwt>` before it
expires: it runs the pinned `ziti` CLI image as you, installs nothing on the host, and writes the
identity, with its private key, to `.devstack/ziti/<name>.json` for `OSL_ICE_ZITI_IDENTITY`. No
tunneler runs on the host and nothing is published: the tunnel pod only dials the broker.

With `ssh`, the tunnel trusts only the VM host key in `~/.ssh/known_hosts` (or
`OSL_ICE_SSH_KNOWN_HOSTS`). Log in once with `ssh <user>@<host>` and check the
fingerprint with the ICE admins before the first `make up`.

The broker connection and CRIDGE run in the `openslice-bridge` namespace.

### What OpenSlice may do in your cluster

Whoever can order a spec for your cluster in OpenSlice acts in it through CRIDGE. With `ice`, that
is anyone with suitable rights on the shared ICE instance, and the docker-reconciler runs what
they order on your machine's Docker. So in both modes CRIDGE does not get the cluster admin but
the `cridge/cridge` ServiceAccount from `manifests/cridge-access.yaml`:

- It may create, change and delete Blueprints and ColonyProcesses, and create and delete
  namespaces, but only namespaces labelled `org.etsi.osl`, which it creates per order. It cannot
  create Pods, BlueprintDefinitions or anything else.
- Blueprints it creates must be `ExecutorDeployment`s or `DockerDeployment`s that use only the
  fields the docker-reconciler defines, and may not ask for privileged containers, host mounts
  or host ports.
- It can read Secrets, Services and ConfigMaps only in namespaces named like an order ID (a
  UUID), where it watches them. RBAC cannot grant rights in namespaces that do not exist yet, so
  a rule in the API server's authorization config (`apiserver/authorization.yaml`) refuses these
  reads everywhere else, such as the colony key in `kolony` and the ColonyOS server key. A
  refused read shows up as an internal server error (500). A cluster created before this rule
  existed does not have it, and `make up` warns about that; recreate it with `make down` and
  `make up`.

`make test` checks these limits (`scripts/test-cridge-access.sh`). Blueprints and namespaces you
create yourself are not restricted.

### Using catalog specs written for another cluster

A CR-based RFSS names its cluster in its resource specification and in the
`currentContextCluster`/`clusterMasterURL` characteristics. Ordering it deploys to *that*
cluster. To use such a spec on your devstack, clone it for your cluster:

```bash
make retarget SPEC="ColonyOS Blueprint Reconciler RFSS"
# -> "ColonyOS Blueprint Reconciler RFSS (cop1-yourname)", ready to bundle into a CFSS and order
```

## Commands

| Command | Does |
|---|---|
| `make up` | create or update everything (idempotent) |
| `make test` | end-to-end tests; adds the OpenSlice order test when `OPENSLICE` is set |
| `make status` | what runs where, and the registered executors |
| `make kolony` | rebuild and redeploy Kolony after changing its source |
| `make colonies`, `make reconciler`, `make openslice` | redeploy one part |
| `make retarget SPEC=...` | clone an RFSS for this cluster |
| `make ziti-enroll JWT=...` | enroll an OpenZiti identity for `OSL_ICE_TRANSPORT=ziti` |
| `make peering-check` | check that a peer can log in and read the catalog at `OPENSLICE_URL` |
| `make checksums` | update `checksums.txt` after changing a tool version |
| `make down` / `make clean` | remove the stack / also remove keys, tools and image caches |

## Configuration

`versions.env` pins every version: k3s, ColonyOS, the reconciler, OpenSlice and the tools.
After changing a tool version there, run `make checksums` to fetch its checksums from the
upstream release into `checksums.txt`, and review the diff.
`devstack.env` (see `devstack.env.example`) holds your local settings. Variables set in the
environment override it.

The cluster pulls its images through pull-through caches, one container per registry
(`devstack-cache-*`, from `scripts/cache.sh`), which keep them in Docker volumes across
`make down`. They are shared by all devstacks on the machine, publish no ports, and k3s falls
back to the registry itself when one is down. A cluster made before the caches existed keeps
pulling directly until it is recreated. Set `IMAGE_CACHE=off` to do without them.

Kolony is built from source so it always matches the ColonyOS version. `KOLONY_GIT` and
`KOLONY_REF` select the source, or set `KOLONY_SRC` to a local checkout. The devstack needs these
Kolony changes, which are not in upstream `main` yet, so it builds a commit of the `devstack`
branch of [nvt/kolony](https://github.com/nvt/kolony), pinned in `versions.env`. Set
`KOLONY_REF=devstack` to build the branch's latest commit instead:

- the `--default-credentials-secret` fallback (OpenSlice creates a namespace per order);
- the colony name on BlueprintDefinitions (the server rejected them before);
- no placeholder credentials Secret from the Helm chart;
- CRDs in the Helm chart in sync with the API.

## How the pieces reach each other

| From | ColonyOS | Kubernetes API |
|---|---|---|
| your shell | `localhost:50080` | `https://127.0.0.1:6550` |
| containers on the k3d network (reconciler, executors) | `k3d-<cluster>-server-0:30080` | `https://k3d-<cluster>-server-0:6443` |
| pods (Kolony, CRIDGE) | `colonies.colonyos.svc.cluster.local:80` | same as above (CRIDGE) |

Kolony reads ColonyOS credentials from `colonyos-credentials` in a CR's namespace. Blueprints and
ColonyProcesses elsewhere fall back to `kolony/colonyos-executor-credentials`, which has no colony
key, but only in namespaces labelled `org.etsi.osl`, as CRIDGE labels the namespaces it creates
for service orders. BlueprintDefinitions live in `kolony`, the only namespace with the colony key.
The reconciler holds the colony key too, so it registers and approves itself and the executors it
starts. No manual `colonies executor approve` is needed.

All keys are generated on first `make up` into `.devstack/identities.env` (mode 600, gitignored).
Nothing secret is committed. The local OpenSlice is reachable only from your machine unless you
publish it elsewhere with `OPENSLICE_URL` or `OPENSLICE_BIND`.

## Troubleshooting

- **`make up` fails at "ColonyOS is deployed but identities.env is gone"**: the cluster's
  database belongs to keys you deleted. Run `make down`, then `make up`.
- **Blueprint never syncs**: `kubectl -n kolony logs deploy/kolony-controller-manager`. Check that
  a BlueprintDefinition for its `spec.kind` is registered (`kubectl get blueprintdefinitions -A`).
- **No executor appears**: `docker logs devstack-<cluster>-reconciler`. The Blueprint's
  `locationName` must equal `LOCATION_NAME` (default `devstack`).
- **OpenSlice order stays INITIAL**: orders placed through the API must be acknowledged
  (`PATCH serviceOrder {"state":"ACKNOWLEDGED"}`). The `OSL_AUTOACK_ORDER` role only applies to
  portal sessions.
- **CFSS service stays `reserved`**: CFSSs that are neither bundles nor `OSAUTOMATED` wait for a
  provider to start them by hand. Make the CFSS a bundle.
- **CRIDGE cannot reach the broker** (`ice`): check the tunnel pod
  (`kubectl -n openslice-bridge logs deploy/broker-tunnel`) and the broker credentials.
- **CRIDGE errors with `emulationMajor`**: the cluster's Kubernetes version is too new for
  CRIDGE's fabric8 client. Keep k3s at v1.31 or v1.32.
