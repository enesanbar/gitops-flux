# Local Kubernetes Cluster (kind)

Local Kubernetes cluster running via [kind](https://kind.sigs.k8s.io/), with custom domain access (`*.kindcluster.dev`) from your browser. Works on macOS (incl. Apple Silicon) and Linux (x86_64/arm64) — `start.sh` detects the OS and configures host DNS accordingly. Two topology profiles:

| Profile | Containers | When to use |
| --- | --- | --- |
| `single` (default) | 1 (control-plane runs workloads) | Day-to-day dev. ~3× less CPU than `multi`. |
| `multi` | 3 (1 control-plane + 2 workers) | Testing scheduling, affinity, drains, upgrades. |

## Prerequisites

- Docker — [Docker Desktop](https://www.docker.com/products/docker-desktop/) on macOS, [Docker Engine](https://docs.docker.com/engine/install/) on Linux (your user in the `docker` group)
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/)
- [Flux CLI](https://fluxcd.io/flux/installation/#install-the-flux-cli)
- [mkcert](https://github.com/FiloSottile/mkcert#installation) (for local TLS certificates)
- `envsubst` — macOS: `brew install gettext`; Debian/Ubuntu: `gettext-base` (usually preinstalled)

`start.sh` checks the hard requirements up front and tells you what's missing.

## Quick Start

```bash
# 1. Create the cluster + networking (single-node by default)
./start.sh
# Or, for the 3-node profile:
./start.sh --topology=multi          # equivalent: KIND_TOPOLOGY=multi ./start.sh

# 2. Bootstrap Flux (first time only, or after a fresh cluster)
cd /path/to/gitops-flux
./scripts/flux/bootstrap.sh

# 3. Wait for Flux to reconcile (~2 minutes), then verify
kubectl get svc -n ingress-nginx
# EXTERNAL-IP should show 172.88.0.200

# 4. Open any configured service in your browser
open http://grafana.kindcluster.dev      # macOS
xdg-open http://grafana.kindcluster.dev  # Linux
```

## Tear Down

```bash
./stop.sh
```

This removes the cluster, proxy containers, dnsmasq, and the Docker network. Host DNS config is left in place (harmless when dnsmasq isn't running). To remove it:

- macOS: `sudo rm /etc/resolver/kindcluster.dev`
- Linux: `sudo rm /etc/systemd/resolved.conf.d/kindcluster-dev.conf && sudo systemctl reload-or-restart systemd-resolved`, and optionally the inotify overrides: `sudo rm /etc/sysctl.d/99-kind-inotify.conf`

The `data-pool-*` directories are kept so PV data survives cluster recreations. On Linux, pods write into them with container UIDs, so wiping them needs `sudo rm -rf data-pool-*`.

## How It Works

When you visit `grafana.kindcluster.dev` in your browser, the request passes through five components before reaching the pod.

### Architecture

```
Browser: grafana.kindcluster.dev
  |
  v
host DNS routing (macOS: /etc/resolver, Linux: systemd-resolved drop-in)
  --> dnsmasq (127.0.0.1:15353) --> resolves to 127.0.0.1
  |
  v
socat (127.0.0.1:80/443) --> forwards to 172.88.0.200:80/443
  |
  v
MetalLB --> responds to ARP, delivers to ingress-nginx
  |
  v
ingress-nginx --> reads Host header, proxies to correct Service
  |
  v
Pod
```

### Component Roles

**Host DNS routing — per-domain redirection to dnsmasq**

One-time, OS-specific setup that sends DNS queries for `kindcluster.dev` (and all subdomains) to dnsmasq, leaving every other domain untouched. No editing needed when you add new services.

- **macOS** — `/etc/resolver/kindcluster.dev`: macOS supports per-domain DNS routing via the `/etc/resolver/` directory; a file named after a domain points queries for it at a custom nameserver (here `127.0.0.1` port `15353`).
- **Linux** — `/etc/systemd/resolved.conf.d/kindcluster-dev.conf`: systemd-resolved supports the same idea via routing domains. `start.sh` writes:

  ```ini
  [Resolve]
  DNS=127.0.0.1:15353
  Domains=~kindcluster.dev
  ```

  The `~` prefix makes it a *routing-only* domain: only `*.kindcluster.dev` queries go to dnsmasq, so VPN/corporate DNS and normal browsing are unaffected. If systemd-resolved isn't running, `start.sh` prints manual alternatives instead of failing.

**dnsmasq — wildcard DNS**

A lightweight DNS server running in a Docker container. Configured with a single rule: any query for `*.kindcluster.dev` returns `127.0.0.1`. Runs on port 15353 to avoid conflicts with system DNS. Starts and stops with the cluster — no persistent system daemon.

**socat — bridge between the host and the Docker network**

On macOS, Docker containers run inside a hidden Linux VM, so container IPs (172.88.x.x) are not directly reachable from the host. socat is a TCP proxy that bridges this gap: it listens on `127.0.0.1:80/443` (reachable by the browser) and forwards to the MetalLB VIP inside the Docker network. On native-Linux Docker the VIP happens to be directly routable, but socat runs there too so the workflow, URLs, and this mental model are identical on both platforms (and Docker Desktop on Linux, which also uses a VM, keeps working).

**MetalLB — LoadBalancer for bare metal**

Kubernetes `Service` type `LoadBalancer` requires a cloud provider to provision an external IP. kind has no cloud provider. MetalLB fills this gap: it watches for LoadBalancer services, assigns an IP from a configured pool (`172.88.0.200-250`), and responds to ARP requests for that IP on the Docker network. This gives the ingress controller a stable, predictable IP.

**ingress-nginx — Host-header routing**

A single entry point for all services. Instead of one LoadBalancer IP per service, ingress-nginx inspects the HTTP `Host` header and routes to the matching backend:

```
Host: grafana.kindcluster.dev   --> grafana Service
Host: kibana.kindcluster.dev    --> kibana Service
```

Each service declares an `Ingress` resource in the cluster. The controller picks it up automatically.

### Why a custom Docker network?

kind normally creates a Docker network with a random subnet. By pre-creating a network with a fixed subnet (`172.88.0.0/16`), the MetalLB pool and socat target IP are always the same. This means:

- No IP changes between cluster recreations
- No conflicts with other kind clusters (each gets its own named network)
- socat config is static — no dynamic IP discovery needed

### What gets managed where

| Component | Managed by | Location |
|-----------|-----------|----------|
| Docker network, kind cluster, socat, dnsmasq | `start.sh` / `stop.sh` | This directory |
| MetalLB, ingress-nginx, cert-manager, apps | Flux GitOps | `gitops-flux` repo |
| mkcert CA secret (per-machine, never in git) | `install-mkcert-ca.sh` (called by `bootstrap.sh`) | `gitops-flux/scripts/flux/` |

## Adding a New Service

Once the cluster is running and Flux is bootstrapped, exposing a new service requires only an `Ingress` resource:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  annotations:
    cert-manager.io/cluster-issuer: mkcert-issuer
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - my-app.kindcluster.dev
      secretName: my-app-tls
  rules:
    - host: my-app.kindcluster.dev
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 80
```

No DNS changes, no socat changes, no config file editing. The domain resolves automatically via dnsmasq, traffic flows through socat to the MetalLB VIP, and ingress-nginx routes by Host header.

## Accessing the Cluster from Another Machine

By default everything binds `127.0.0.1`, so the cluster is reachable only from the machine it runs on. To offload the cluster to a second machine (e.g. a spare Linux box) and still type `<app>.kindcluster.dev` in the browser on your laptop, split the two halves of the chain across the two machines:

- **Server** (runs the cluster) publishes the ingress proxies on the LAN instead of loopback.
- **Client** (your laptop, no cluster) runs *only* dnsmasq, resolving `*.kindcluster.dev` to the server's IP.

```
Laptop browser: grafana.kindcluster.dev
  --> host DNS routing --> dnsmasq on laptop --> resolves to SERVER_IP
  --> SERVER_IP:80/443 (over the LAN)
  --> socat on server (bound 0.0.0.0) --> MetalLB VIP --> ingress-nginx --> Pod
```

### 1. On the server — expose the ingress

```bash
./start.sh --expose-lan          # binds the socat proxies to 0.0.0.0
```

`--expose-lan` binds `0.0.0.0`, so **the server doesn't care what its own IP is** — this survives DHCP lease changes without re-running anything on the server. (Cluster already running? This only recreates the two proxy containers; the cluster is untouched.) Use `--bind-address=<ip>` instead if you want to pin a single interface.

> **Security:** this makes the cluster ingress reachable by any host that can route to the server. Only do it on a trusted LAN. `start.sh` prints a warning when the bind address isn't loopback.

### 2. On the client (laptop) — point DNS at the server

The server's LAN IP is the *one* value that changes under DHCP, so keep it in a variable and everything below re-runs cleanly whenever it moves:

```bash
REMOTE_IP=192.168.0.155          # ← the only thing to update when DHCP reassigns
./start.sh --remote-host="$REMOTE_IP"
```

This runs dnsmasq only (no cluster, no network, no proxies) and wires host DNS. Find the server's current IP on the server with `hostname -I` (Linux) or `ipconfig getifaddr en0` (macOS).

**When the server's IP changes:** just re-run the client command with the new `REMOTE_IP`. Nothing else moves.

### 3. TLS — trust the server's mkcert CA

The ingress serves certs signed by the mkcert root CA **on the server**, which your laptop doesn't know — hence cert warnings. Copy the CA over. No SSH server is required; use the LAN you already have.

First check whether you even need to — if the fingerprints already match, your laptop trusts it and you can skip the rest:

```bash
# server:  openssl x509 -in "$(mkcert -CAROOT)/rootCA.pem" -noout -fingerprint -sha256
# laptop:  openssl x509 -in "$(mkcert -CAROOT)/rootCA.pem" -noout -fingerprint -sha256
```

Different fingerprints → copy the server's CA over HTTP:

```bash
# On the server — serve the CA dir briefly (Ctrl-C when done):
cd "$(mkcert -CAROOT)" && python3 -m http.server 8000 --bind "$REMOTE_IP"
#   no python3? you already have Docker:
#   docker run --rm -p "$REMOTE_IP":8000:80 -v "$(mkcert -CAROOT)":/usr/share/nginx/html:ro nginx:alpine

# On the laptop — pull it and trust it (macOS):
curl -o /tmp/remote-rootCA.pem "http://$REMOTE_IP:8000/rootCA.pem"
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /tmp/remote-rootCA.pem
#   Linux:
#   sudo cp /tmp/remote-rootCA.pem /usr/local/share/ca-certificates/kindcluster-remote.crt && sudo update-ca-certificates
```

This *adds* trust for the server's CA without touching your laptop's own mkcert CA. Restart the browser afterward. The CA rarely changes, so this is a one-time step per server (only redo it if the server re-runs `mkcert -install`).

## Cluster Topology & Storage Pools

### Two profiles

| File | Profile | Nodes | Storage pools on which node |
| --- | --- | --- | --- |
| `config.single.yaml` | single | 1 control-plane (untainted) | both `data-pool-1` and `data-pool-2` on the control-plane |
| `config.multi.yaml`  | multi  | 1 control-plane + 2 workers | `data-pool-1` on worker-1, `data-pool-2` on worker-2 |

### Storage pools — what they are

A "storage pool" is a directory on the host (`scripts/cluster-setup/kind/data-pool-{1,2}`) bind-mounted into the kind node container at `/mnt/data-pool-{1,2}`. PVs with `hostPath: /mnt/data-pool-N/<subdir>` survive cluster recreations because the data lives on the host. `stop.sh` deletes the cluster but leaves the pools alone.

The host directories are gitignored. `start.sh` creates them if missing. On Linux, files written by pods keep their container UIDs (e.g. postgres' `999`), so cleaning a pool requires `sudo rm -rf`; on macOS, Docker Desktop's file sharing maps everything to your user.

### What lives in which pool

Convention: **pool-1 = application state, pool-2 = observability.** In the multi-node profile that puts apps on worker-1 and telemetry churn (Prometheus TSDB, Elasticsearch) on worker-2.

| Pool | Host subdir | PV | Bound PVC (namespace/name) | Manifest |
| --- | --- | --- | --- | --- |
| 1 | `n8n` | `n8n` | `n8n/n8n` | `clusters/dev-cluster/components/infrastructure/n8n/pvc.yaml` |
| 1 | `n8n-encryption-key` | — (file, not a PV) | read by `scripts/flux/install-n8n-secrets.sh` | — |
| 1 | `keycloak-postgres-data` | `keycloak-postgres-data` | `keycloak/keycloak-postgres-data` | `components/keycloak/postgres-pvc.yaml` |
| 1 | `trellis-pg` | `trellis-pg-1` | `trellis/trellis-pg-1` (the CloudNativePG operator's own claim, `<cluster>-<serial>`) | `clusters/dev-cluster/components/apps/trellis/pv.yaml` |
| 2 | `monitoring-prometheus` | `monitoring-prometheus` | `monitoring/prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0` | `.../kube-prometheus-stack/pv.yaml` |
| 2 | `monitoring-alertmanager` | `monitoring-alertmanager` | `monitoring/alertmanager-kube-prometheus-stack-alertmanager-db-alertmanager-kube-prometheus-stack-alertmanager-0` | `.../kube-prometheus-stack/pv.yaml` |
| 2 | `monitoring-grafana` | `monitoring-grafana` | `monitoring/grafana` | `.../kube-prometheus-stack/pv.yaml` |
| 2 | `monitoring-elasticsearch` | `monitoring-elasticsearch` | `monitoring/elasticsearch-data-elasticsearch-es-default-0` | `.../elasticsearch/pv.yaml` |
| 2 | `observability-tempo` | `observability-tempo` | `observability/storage-tempo-0` | `.../tempo/pv.yaml` |
| 2 | `observability-loki` | `observability-loki` | `observability/storage-loki-0` | `.../loki/pv.yaml` |
| 2 | `observability-jaeger` | `observability-jaeger` | `observability/jaeger-badger` | `.../jaeger/pv.yaml` |

`...` = `clusters/dev-cluster/components/infrastructure`. Deliberately *not* on a pool: Logstash's queue, Filebeat's registry (per-node hostPath under `/var/lib`, managed by ECK), the OTel collector (stateless), SigNoz and Redis (scratch).

### Declaring a pool-backed PV

Copy this. It goes in the **cluster overlay** (`clusters/dev-cluster/components/infrastructure/<comp>/pv.yaml`), because host paths are a property of this kind setup, not of the component.

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: observability-tempo                 # <namespace>-<purpose>; cluster-scoped, unique
spec:
  storageClassName: standard                # same class the PVC will ask for; claimRef pre-binds, so nothing dynamic runs
  persistentVolumeReclaimPolicy: Retain
  accessModes: [ReadWriteOnce]
  capacity:
    storage: 10Gi                           # >= the PVC request
  hostPath:
    path: /mnt/data-pool-2/observability-tempo
    type: DirectoryOrCreate
  nodeAffinity:                             # the scheduler follows the volume; no nodeSelector needed on the pod
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: gitops-flux.local/data-pool-2
              operator: In
              values: ["true"]
  claimRef:                                 # exact PVC the workload will create or that you declare next to this
    namespace: observability
    name: storage-tempo-0
```

- **StatefulSets** (Prometheus, Alertmanager, Tempo, Loki, Elasticsearch) create their own PVC; only the `claimRef` is needed. Kubernetes binds a PV whose `claimRef` names a not-yet-existing PVC the moment that PVC appears, even with `WaitForFirstConsumer`. The generated name is `<volumeClaimTemplate name>-<statefulset name>-<ordinal>`; check with `kubectl get pvc -n <ns>` on a running instance.
- **Deployments** (Grafana, Jaeger, n8n) don't create PVCs: declare one next to the PV with `volumeName` pointing back at it, and hand it to the chart via `existingClaim` / `extraVolumes`.
- `nodeAffinity` on the PV is the preferred pinning mechanism. Older manifests used a `nodeSelector` on the pod against the same label; both work, but the affinity lives with the data and cannot be forgotten when a chart is swapped. `hostPath` is immutable once a PV exists, so retrofits can add `nodeAffinity` but not change `type`.

### Pinning pods to a pool (legacy)

If you cannot use PV `nodeAffinity` (e.g. an operator that owns the PV), select on the pool label, **not** the hostname:

```yaml
# Lands on whichever node hosts data-pool-1.
nodeSelector:
  gitops-flux.local/data-pool-1: "true"
```

Why labels and not `kubernetes.io/hostname: local-dind-cluster-worker`? Because the hostname depends on the topology (`...-control-plane` vs `...-worker`) and the index suffix. The pool label is topology-independent: in `single` the lone node carries both labels; in `multi` each worker carries one. Same workload manifest works on either.

### Verifying persistence after a reinit

```bash
kubectl get pv | grep -E 'monitoring-|observability-|^n8n|keycloak|trellis-pg'   # all Bound, to the PVC names in the table
ls scripts/cluster-setup/kind/data-pool-2/                             # one subdir per PV, growing
# Elasticsearch's generated password (ECK):
kubectl -n monitoring get secret elasticsearch-es-elastic-user -o go-template='{{.data.elastic | base64decode}}'
```

### Adding a new pool

If you want a third pool (rare):

1. Add `data-pool-3` to `.gitignore` (already covered by `data-pool-*`).
2. Add a mount + label to each config (in `single`, also on the control-plane; in `multi`, either pin to an existing worker or add a third).
3. Reference it from your PV as `hostPath: /mnt/data-pool-3/<subdir>` with `nodeAffinity` on `gitops-flux.local/data-pool-3`.

## Linux notes

`start.sh` handles two Linux-only concerns automatically (both idempotent, both `sudo`-prompting with the content printed first):

**inotify limits.** kind on Linux commonly exhausts the kernel's default inotify limits once Flux, ingress-nginx, and the observability stack are running — pods crash-loop with `too many open files`. `start.sh` raises `fs.inotify.max_user_watches` to 524288 and `fs.inotify.max_user_instances` to 512 via `/etc/sysctl.d/99-kind-inotify.conf` (it never lowers values you've already raised). Set `KIND_SKIP_SYSCTL=1` to skip; remove the file to undo.

**Wildcard DNS via systemd-resolved.** See "Host DNS routing" above. Requires systemd ≥ 246 (Ubuntu 22.04+). If systemd-resolved isn't active, `start.sh` prints manual alternatives (NetworkManager's dnsmasq mode, or per-host `/etc/hosts` entries) and continues — the cluster itself works either way.

## Troubleshooting

**DNS not resolving:**
```bash
dig @127.0.0.1 -p 15353 test.kindcluster.dev
# Should return 127.0.0.1
```
If not, check dnsmasq: `docker logs kind-dnsmasq`

If dnsmasq answers but the browser/curl can't resolve, check the OS routing layer:

```bash
# Linux — both should return 127.0.0.1
resolvectl query test.kindcluster.dev
getent hosts test.kindcluster.dev
# 'resolvectl status' should list "DNS Servers: 127.0.0.1:15353" with "DNS Domain: ~kindcluster.dev"

# macOS — plain `dig` BYPASSES /etc/resolver; use the system path instead:
dscacheutil -q host -a name test.kindcluster.dev
scutil --dns | grep -B1 -A3 kindcluster
```

(On Linux plain `dig` does go through systemd-resolved, so it works there.) One known edge on Linux: a custom global `DNS=` in `/etc/systemd/resolved.conf` shares scope with the drop-in and makes `kindcluster.dev` resolution nondeterministic — scope that server to a domain or remove it.

**Pods crash-looping with `too many open files` (Linux):**
```bash
sysctl fs.inotify.max_user_watches fs.inotify.max_user_instances
# Want >= 524288 / 512 — see "Linux notes" above
```

**EXTERNAL-IP stuck at `<pending>`:**
```bash
kubectl get ipaddresspools.metallb.io -A
kubectl get l2advertisements.metallb.io -A
```
If empty, MetalLB pool config hasn't been applied. Check Flux: `flux get kustomizations | grep metallb`

**Connection refused on localhost:80:**
```bash
docker ps --filter "name=proxy-ingress"
```
If socat containers aren't running, restart them with `./start.sh` (idempotent).

**Ingress returns 404:**
Verify the Ingress resource exists and has `ingressClassName: nginx`:
```bash
kubectl get ingress -A
```
