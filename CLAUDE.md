# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Flux CD GitOps repository: every change to Kubernetes state goes through Git, and Flux reconciles it onto target clusters. There is no application code here — only Kubernetes manifests, Helm releases, and the scripts that bootstrap a local kind cluster.

## Common commands

```bash
# Spin up local kind cluster + Docker network + socat ingress proxies + dnsmasq
./scripts/cluster-setup/kind/start.sh

# Tear it all down
./scripts/cluster-setup/kind/stop.sh

# Bootstrap Flux against this repo (requires GITHUB_TOKEN env var; first run only)
./scripts/flux/bootstrap.sh kind-local-dind-cluster <github-user> gitops-flux main clusters/dev-cluster

# Inspect / debug Flux reconciliation
flux get kustomizations
flux get helmreleases -A
flux reconcile kustomization <name> --with-source     # force a re-sync
flux logs --kind=Kustomization --name=<name> -f       # follow controller logs

# When editing a Kustomization locally, render it before committing
kubectl kustomize clusters/dev-cluster
kubectl kustomize components/<component>
```

There is no build, lint, or test tooling in this repo. Validation is "does `kubectl kustomize` render cleanly" and "does Flux reconcile the change on the cluster".

## Architecture — the two-layer Kustomization pattern

This is the single most important thing to understand before editing anything. Every component appears in **two** places that mean different things:

1. **`components/<name>/`** — the actual Kubernetes manifests (Namespace, HelmRelease, Deployment, Ingress, etc.). These are the shared building blocks. A `kustomization.yaml` here is a *Kustomize* `Kustomization` (`kustomize.config.k8s.io/v1beta1`).

2. **`clusters/<cluster>/components/{infrastructure,apps}/<name>/kustomization.yaml`** — a thin shim that references the shared component via relative path (`../../../../../components/<name>`). This is what makes a component "active" for that cluster.

3. **`clusters/<cluster>/components/{infrastructure,apps}/flux-system/kustomize/<name>.yaml`** — a *Flux* `Kustomization` (`kustomize.toolkit.fluxcd.io/v1`) that tells Flux to reconcile the path from step 2. This is what makes Flux actually apply it.

Mental model: `components/` is a library, `clusters/<cluster>/components/` enables specific items from that library, and `clusters/<cluster>/components/.../flux-system/kustomize/` is the registry Flux reads to drive reconciliation.

**To enable a new component on a cluster, all three must line up.** Adding a manifest under `components/foo/` does nothing on its own; Flux only sees what is listed in `clusters/<cluster>/components/{infrastructure,apps}/flux-system/kustomize/kustomization.yaml`. Conversely, commenting a line out in that file is how features get disabled — `#- mongodb.yaml`, `#- rabbitmq.yaml`, and `#- fleetman-microservices.yaml` are real examples currently in the tree.

### Infrastructure vs apps split

Per-cluster, components are partitioned:

- `infrastructure/` — cluster-wide platform: ingress-nginx, cert-manager, metallb, monitoring stack, operators (postgres-operator, openclaw-operator), keycloak, redis, mongodb, etc.
- `apps/` — workloads that depend on infrastructure: kubia, fleetman-microservices, openclaw instances, kubeclaw instances.

There is no enforced ordering between the two; both reconcile in parallel. If an app needs an operator CRD, the app's Flux Kustomization will retry on its `retryInterval` until the CRD exists.

### Helm sources

`HelmRepository` resources live in `components/flux-system/sources/helm-repositories/` and are loaded once via `clusters/<cluster>/kustomization.yaml`. A `HelmRelease` in any component just references one of these by name (e.g., `sourceRef.name: jetstack` for cert-manager). When adding a HelmRelease that pulls from a new chart repository, add the `HelmRepository` here and register it in `helm-repositories/kustomization.yaml`.

## Dev cluster networking (kind + macOS specifics)

The local dev story is non-trivial because Docker containers on macOS run inside a hidden Linux VM, so kind node IPs aren't directly reachable from the host. `start.sh` stitches together five pieces to make `*.kindcluster.dev` Just Work in the browser:

```
Browser (https://x.kindcluster.dev)
  -> /etc/resolver/kindcluster.dev (macOS per-domain DNS)
  -> dnsmasq @ 127.0.0.1:15353 (Docker container, resolves *.kindcluster.dev -> 127.0.0.1)
  -> socat @ 127.0.0.1:80/443 (Docker container, forwards to MetalLB VIP 172.88.0.200)
  -> MetalLB (assigns 172.88.0.200 to ingress-nginx, answers ARP)
  -> ingress-nginx (Host-header routing to the target Service)
```

The Docker network `kind-local-dind-cluster` is pre-created with a fixed subnet `172.88.0.0/16` precisely so the MetalLB pool (`172.88.0.200-250`) and the socat target are stable across cluster recreations. `/etc/resolver/kindcluster.dev` is a one-time `sudo` write and is intentionally left in place by `stop.sh`.

Worker nodes mount `scripts/cluster-setup/kind/worker-{1,2}-localpathprovisioner-data/` into `/mnt/data` so local-path-provisioner PVCs survive cluster restarts. The `*-localpathprovisioner-data*` paths are gitignored.

Full breakdown of why each piece exists: `scripts/cluster-setup/kind/README.md`.

## TLS for local development

`scripts/flux/bootstrap.sh` runs `mkcert -install` on the host, then writes the mkcert root CA into a `mkcert-ca-key-pair` secret under `cert-manager` namespace, materialized at `clusters/dev-cluster/components/infrastructure/cert-issuer/mkcert-ca-secret.yaml`. That secret is then consumed by a cert-manager ClusterIssuer (`mkcert-issuer`). Any Ingress that wants TLS just sets:

```yaml
annotations:
  cert-manager.io/cluster-issuer: mkcert-issuer
```

The secret file is generated locally and committed; do not delete it without re-running bootstrap, or cert-manager will fail to issue certs for dev ingresses.

## Adding a new component

The minimum complete change to add component `foo` to the dev cluster:

1. Create `components/foo/` with `namespace.yaml`, `kustomization.yaml`, and either a `helm-release.yaml` or raw manifests.
2. Create `clusters/dev-cluster/components/{infrastructure|apps}/foo/kustomization.yaml` containing a single resource: `../../../../../components/foo`.
3. Create `clusters/dev-cluster/components/{infrastructure|apps}/flux-system/kustomize/foo.yaml` as a Flux `Kustomization` pointing at `./clusters/dev-cluster/components/{infrastructure|apps}/foo` (copy from a sibling like `cert-manager.yaml`).
4. Append `- foo.yaml` to `clusters/dev-cluster/components/{infrastructure|apps}/flux-system/kustomize/kustomization.yaml`.
5. If pulling from a new Helm chart repo, also add a `HelmRepository` under `components/flux-system/sources/helm-repositories/` and register it there.

Skipping any of steps 2-4 is the most common mistake — the manifests will sit unused.

## Cluster-specific notes

- **`clusters/dev-cluster/`** is the only fully-wired cluster. `prod-cluster/` is a stub that currently only references a couple of fleetman manifests; treat it as aspirational rather than functional.
- The Flux bootstrap targets the dev cluster path by default; pass a different `clusters/<name>` path to bootstrap a different cluster.
- The `kubeclaw-instances`, `openclaw-operator-instances`, and `openclaw-raw-instances` directories under `clusters/dev-cluster/components/apps/` are gitignored — they hold environment-specific generated instances and should not be committed.

## ArgoCD script

`scripts/argocd/` exists as an alternative bootstrap path (Helm-install ArgoCD with bundled `values.yaml`) for experimentation. It is not part of the Flux flow and is not invoked by anything else; leave it alone unless explicitly working on ArgoCD.
