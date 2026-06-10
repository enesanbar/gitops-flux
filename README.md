# GitOps with Flux

A GitOps repository managed by [Flux CD](https://fluxcd.io/) for declarative Kubernetes cluster configuration.

## Pre-requisites

| Tool | Purpose |
|------|---------|
| [Docker](https://docs.docker.com/get-docker/) | Container runtime for kind — Docker Desktop (macOS) or Docker Engine (Linux) |
| [kind](https://kind.sigs.k8s.io/) | Local Kubernetes cluster |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | Kubernetes CLI |
| [Flux CLI](https://fluxcd.io/flux/installation/) | Bootstrap and manage Flux |
| [mkcert](https://github.com/FiloSottile/mkcert) | Local TLS certificates |
| [Helm](https://helm.sh/docs/intro/install/) | Helm chart management |
| `envsubst` | Template processing (macOS: `brew install gettext`; Debian/Ubuntu: `gettext-base`, usually preinstalled) |

## Getting Started

### 1. Create the local kind cluster

```bash
./scripts/cluster-setup/kind/start.sh
```

This will:
- Create a dedicated Docker network
- Spin up a kind cluster (single-node by default; `--topology=multi` for 1 control-plane + 2 workers)
- Merge the kubeconfig into `~/.kube/config`
- Set up socat proxies for ingress on `127.0.0.1:80/443`
- Configure local DNS so `*.kindcluster.dev` resolves to `127.0.0.1` (macOS `/etc/resolver`, Linux systemd-resolved)

Works on both macOS (incl. Apple Silicon) and Linux — see [scripts/cluster-setup/kind/README.md](scripts/cluster-setup/kind/README.md) for details.

### 2. Bootstrap Flux

```bash
export GITHUB_TOKEN=<your-github-pat>

./scripts/flux/bootstrap.sh \
  kind-local-dind-cluster \
  <your-github-username> \
  gitops-flux \
  main \
  clusters/dev-cluster
```

| Argument | Default | Description |
|----------|---------|-------------|
| `KUBE_CONTEXT` | `kind-local-dind-cluster` | kubectl context to use |
| `GITHUB_USERNAME` | `enesanbar` | GitHub repo owner |
| `GITHUB_REPO` | `gitops-flux` | Repository name |
| `BRANCH` | `main` | Branch to reconcile |
| `PATH` | `clusters/dev-cluster` | Path inside the repo for Flux kustomizations |

This will:
- Install the mkcert root CA as a cert-manager secret (for local TLS)
- Bootstrap Flux and point it at this repository

### Local TLS — per-machine mkcert CA

The `mkcert-issuer` ClusterIssuer lives in git, but the CA key pair it signs with does **not**: `scripts/flux/install-mkcert-ca.sh` (called by `bootstrap.sh`) installs *this machine's* mkcert CA into the cluster as the `cert-manager/mkcert-ca-key-pair` secret. Because `mkcert -install` registers the same CA in your local trust stores, every certificate the cluster issues is trusted by your browser — no warnings, and no key material in git.

When switching the cluster to another machine (or after rotating the CA), refresh the secret and force re-issuance of all certificates:

```bash
./scripts/flux/install-mkcert-ca.sh --renew-all
```

Linux notes: browser trust needs `certutil` (`sudo apt-get install libnss3-tools`) before running `mkcert -install`; if snap-packaged Firefox still warns, set `security.enterprise_roots.enabled` to `true` in `about:config`.

### 3. Verify

```bash
flux get kustomizations
kubectl get pods -A
```

## Repository Structure

```
clusters/           # Per-cluster Flux entrypoints
  dev-cluster/      # Dev environment
  prod-cluster/     # Production environment
components/         # Shared Kubernetes manifests (Helm releases, namespaces, etc.)
scripts/            # Cluster setup and bootstrap scripts
```

## Tearing Down

```bash
./scripts/cluster-setup/kind/stop.sh
```

This removes the cluster, the socat/dnsmasq helper containers, and the dedicated Docker network.