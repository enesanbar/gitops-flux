# Local Kubernetes Cluster (kind)

Local Kubernetes cluster running via [kind](https://kind.sigs.k8s.io/), with custom domain access (`*.kindcluster.dev`) from your browser. Two topology profiles:

| Profile | Containers | When to use |
| --- | --- | --- |
| `single` (default) | 1 (control-plane runs workloads) | Day-to-day dev. ~3× less CPU than `multi`. |
| `multi` | 3 (1 control-plane + 2 workers) | Testing scheduling, affinity, drains, upgrades. |

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/)
- [Flux CLI](https://fluxcd.io/flux/installation/#install-the-flux-cli)
- [mkcert](https://github.com/FiloSottile/mkcert#installation) (for local TLS certificates)

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
open http://grafana.kindcluster.dev
```

## Tear Down

```bash
./stop.sh
```

This removes the cluster, proxy containers, dnsmasq, and the Docker network. The `/etc/resolver/kindcluster.dev` file is left in place (harmless when dnsmasq isn't running). To remove it: `sudo rm /etc/resolver/kindcluster.dev`.

## How It Works

When you visit `grafana.kindcluster.dev` in your browser, the request passes through five components before reaching the pod.

### Architecture

```
Browser: grafana.kindcluster.dev
  |
  v
/etc/resolver/kindcluster.dev --> dnsmasq (127.0.0.1:15353) --> resolves to 127.0.0.1
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

**`/etc/resolver/kindcluster.dev` — macOS DNS routing**

macOS supports per-domain DNS routing via the `/etc/resolver/` directory. A file named after a domain tells macOS to send DNS queries for that domain to a custom nameserver. This is a one-time setup that covers all subdomains — no editing needed when you add new services.

**dnsmasq — wildcard DNS**

A lightweight DNS server running in a Docker container. Configured with a single rule: any query for `*.kindcluster.dev` returns `127.0.0.1`. Runs on port 15353 to avoid conflicts with system DNS. Starts and stops with the cluster — no persistent system daemon.

**socat — bridge between macOS and Docker**

On macOS, Docker containers run inside a hidden Linux VM. Container IPs (172.88.x.x) are not directly reachable from the host. socat is a TCP proxy that bridges this gap: it listens on `127.0.0.1:80/443` (reachable by the browser) and forwards to the MetalLB VIP inside the Docker network.

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
| mkcert CA secret | `bootstrap.sh` | `gitops-flux/scripts/flux/` |

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

## Cluster Topology & Storage Pools

### Two profiles

| File | Profile | Nodes | Storage pools on which node |
| --- | --- | --- | --- |
| `config.single.yaml` | single | 1 control-plane (untainted) | both `data-pool-1` and `data-pool-2` on the control-plane |
| `config.multi.yaml`  | multi  | 1 control-plane + 2 workers | `data-pool-1` on worker-1, `data-pool-2` on worker-2 |

### Storage pools — what they are

A "storage pool" is a host directory on the macOS side (`scripts/cluster-setup/kind/data-pool-{1,2}`) bind-mounted into the kind node container at `/mnt/data-pool-{1,2}`. PVs with `hostPath: /mnt/data-pool-N/<subdir>` survive cluster recreations because the data lives on the host.

The host directories are gitignored. `start.sh` creates them if missing and renames any legacy `worker-{1,2}-localpathprovisioner-data/` dirs from previous setups.

### Pinning pods to a pool

Workloads that need pool-local data declare a node selector against the pool label, **not** the hostname:

```yaml
# Lands on whichever node hosts data-pool-1.
nodeSelector:
  gitops-flux.local/data-pool-1: "true"
```

Why labels and not `kubernetes.io/hostname: local-dind-cluster-worker`? Because the hostname depends on the topology (`...-control-plane` vs `...-worker`) and the index suffix. The pool label is topology-independent: in `single` the lone node carries both labels; in `multi` each worker carries one. Same workload manifest works on either.

### Adding a new pool

If you want a third pool (rare):

1. Add `data-pool-3` to `.gitignore` (already covered by `data-pool-*`).
2. Add a mount + label to each config (in `single`, also on the control-plane; in `multi`, either pin to an existing worker or add a third).
3. Reference it from your PV as `hostPath: /mnt/data-pool-3/<subdir>` and from your pod as `nodeSelector: gitops-flux.local/data-pool-3: "true"`.

## Troubleshooting

**DNS not resolving:**
```bash
dig @127.0.0.1 -p 15353 test.kindcluster.dev
# Should return 127.0.0.1
```
If not, check dnsmasq: `docker logs kind-dnsmasq`

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
