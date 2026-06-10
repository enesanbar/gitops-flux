#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KUBE_CONTEXT_NAME=${1:-"kind-local-dind-cluster"}
GITHUB_USERNAME=${2:-"enesanbar"}
GITHUB_REPO=${3:-"gitops-flux"}
GITHUB_REPO_BRANCH=${4:-"main"}
GITHUB_REPO_PATH=${5:-"clusters/dev-cluster"}

: "${GITHUB_TOKEN:?GITHUB_TOKEN must be set (GitHub PAT with repo scope) for 'flux bootstrap github'}"

kubectl config use-context "${KUBE_CONTEXT_NAME}"

# Install this machine's mkcert CA as the cert-manager signing secret.
# Kept out of git on purpose — see install-mkcert-ca.sh. Re-run that script
# standalone after recreating the cluster or rotating the CA.
"${SCRIPT_DIR}/install-mkcert-ca.sh" "${KUBE_CONTEXT_NAME}"

# Install the flux components in the cluster
flux bootstrap github \
  --owner="${GITHUB_USERNAME}" \
  --repository="${GITHUB_REPO}" \
  --branch="${GITHUB_REPO_BRANCH}" \
  --path="${GITHUB_REPO_PATH}"
