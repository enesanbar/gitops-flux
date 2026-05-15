# GitOps with Flux

A GitOps repository managed by [Flux CD](https://fluxcd.io/) for declarative Kubernetes cluster configuration.

## Pre-requisites

| Tool | Purpose |
|------|---------|
| [Docker](https://docs.docker.com/get-docker/) | Container runtime for kind |
| [kind](https://kind.sigs.k8s.io/) | Local Kubernetes cluster |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | Kubernetes CLI |
| [Flux CLI](https://fluxcd.io/flux/installation/) | Bootstrap and manage Flux |
| [mkcert](https://github.com/FiloSottile/mkcert) | Local TLS certificates |
| [Helm](https://helm.sh/docs/intro/install/) | Helm chart management |
| `envsubst` | Template processing (macOS: `brew install gettext`) |

## Getting Started

### 1. Create the local kind cluster

```bash
./scripts/cluster-setup/kind/start.sh
```

This will:
- Create a dedicated Docker network
- Spin up a kind cluster with 1 control-plane + 2 worker nodes
- Merge the kubeconfig into `~/.kube/config`
- Set up socat proxies for ingress on `127.0.0.1:80/443`
- Configure local DNS so `*.kindcluster.dev` resolves to `127.0.0.1`

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
kind delete cluster --name local-dind-cluster
docker rm -f proxy-ingress-80 proxy-ingress-443 kind-dnsmasq 2>/dev/null
```