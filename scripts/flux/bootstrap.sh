#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KUBE_CONTEXT_NAME=${1:-"kind-local-dind-cluster"}
GITHUB_USERNAME=${2:-"enesanbar"}
GITHUB_REPO=${3:-"gitops-flux"}
GITHUB_REPO_BRANCH=${4:-"main"}
GITHUB_REPO_PATH=${5:-"clusters/dev-cluster"}

: "${GITHUB_TOKEN:?GITHUB_TOKEN must be set (GitHub PAT with repo scope) for 'flux bootstrap github'}"

# Preflight for the install-*-secrets.sh steps below, run before anything
# touches the cluster: the same KIND_DATA_ROOT and REQUIRE_EXISTING_SECRETS rules
# they apply, and with the switch on, every key file they need. The installers
# keep their own checks because they also run standalone. With neither variable
# set this only validates and passes.
preflight_key_material() {
  local root file missing=0
  if [ -n "${KIND_DATA_ROOT+set}" ]; then
    root="${KIND_DATA_ROOT}"
    if [ -z "${root}" ]; then
      echo "ERROR: KIND_DATA_ROOT is set but empty; unset it to use the default pool" >&2
      exit 1
    fi
    while [ "${root}" != "/" ] && [ "${root%/}" != "${root}" ]; do
      root="${root%/}"
    done
    if ! [[ "${root}" =~ ^(/[A-Za-z0-9._-]+)+$ ]]; then
      echo "ERROR: KIND_DATA_ROOT must be an absolute path made of letters, digits, '.', '_', '-' and '/' (got '${root}')" >&2
      exit 1
    fi
  else
    root="${SCRIPT_DIR}/../cluster-setup/kind"
  fi
  case "${REQUIRE_EXISTING_SECRETS-0}" in
    0) return 0 ;;
    1) ;;
    *)
      echo "ERROR: REQUIRE_EXISTING_SECRETS must be 0 or 1 (got '${REQUIRE_EXISTING_SECRETS}')" >&2
      exit 1
      ;;
  esac
  for file in n8n-encryption-key \
    onyx-secrets/postgres-password onyx-secrets/opensearch-admin-password \
    onyx-secrets/redis-password onyx-secrets/user-auth-secret \
    pgadmin-secrets/admin-password; do
    if [ ! -s "${root}/data-pool-1/${file}" ]; then
      echo "ERROR: ${root}/data-pool-1/${file} is missing or empty, and REQUIRE_EXISTING_SECRETS=1 forbids generating it" >&2
      missing=1
    fi
  done
  if [ "${missing}" -ne 0 ]; then
    echo "       Copy the existing key material into ${root}/data-pool-1 first. Nothing was changed." >&2
    exit 1
  fi
}
preflight_key_material

kubectl config use-context "${KUBE_CONTEXT_NAME}"

# Install this machine's mkcert CA as the cert-manager signing secret.
# Kept out of git on purpose — see install-mkcert-ca.sh. Re-run that script
# standalone after recreating the cluster or rotating the CA.
"${SCRIPT_DIR}/install-mkcert-ca.sh" "${KUBE_CONTEXT_NAME}"

# Restore host-only sealing keys and the local Vault CA trust BEFORE Flux can
# start the controllers. Missing custody material is a hard stop, not new keys.
KUBE_CONTEXT="${KUBE_CONTEXT_NAME}" "${SCRIPT_DIR}/../secrets/prepare-local.sh"

# n8n's encryption key + runtime Secret. Also kept out of git; the key lives
# next to the n8n data in data-pool-1 so reinits keep credentials readable.
"${SCRIPT_DIR}/install-n8n-secrets.sh" "${KUBE_CONTEXT_NAME}"

# Onyx's Postgres, OpenSearch, Redis and auth credentials. Kept in data-pool-1
# beside the data they unlock; must exist before Flux creates the CNPG Cluster.
"${SCRIPT_DIR}/install-onyx-secrets.sh" "${KUBE_CONTEXT_NAME}"

# pgAdmin's web login, plus the per-database passwords it connects with, copied
# out of the namespaces that own them. Safe to re-run: anything not created yet
# is skipped, and the Secret is mounted as a directory so a later run refreshes
# it without restarting the pod.
"${SCRIPT_DIR}/install-pgadmin-secrets.sh" "${KUBE_CONTEXT_NAME}"

# Install the flux components in the cluster
flux bootstrap github \
  --owner="${GITHUB_USERNAME}" \
  --repository="${GITHUB_REPO}" \
  --branch="${GITHUB_REPO_BRANCH}" \
  --path="${GITHUB_REPO_PATH}"
