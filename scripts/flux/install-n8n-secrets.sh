#!/usr/bin/env bash
set -euo pipefail

# Installs the runtime Secret (n8n/n8n-secrets) that the n8n Helm chart reads
# N8N_ENCRYPTION_KEY, N8N_HOST, N8N_PORT and N8N_PROTOCOL from
# (clusters/dev-cluster/components/infrastructure/n8n/helm-release.yaml,
# secretRefs.existingSecret).
#
# The encryption key protects every credential stored in n8n's database, so it
# is deliberately NOT in git. It is kept next to the pool data it encrypts
# (scripts/cluster-setup/kind/data-pool-1/n8n-encryption-key): a cluster reinit
# reuses the same key for the same database, and wiping the pool removes both.
# Losing the key means losing every stored credential.
#
# Usage: install-n8n-secrets.sh [kube-context]
# Env:   N8N_HOST / N8N_PORT / N8N_PROTOCOL override the public URL parts.

KUBE_CONTEXT_NAME="${1:-kind-local-dind-cluster}"
NAMESPACE="n8n"
SECRET_NAME="n8n-secrets"
N8N_HOST="${N8N_HOST:-n8n.kindcluster.dev}"
N8N_PORT="${N8N_PORT:-5678}"
N8N_PROTOCOL="${N8N_PROTOCOL:-https}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POOL_DIR="${SCRIPT_DIR}/../cluster-setup/kind/data-pool-1"
KEY_FILE="${POOL_DIR}/n8n-encryption-key"
# n8n's own settings file on the PV; it records the key the database was
# encrypted with when the instance was created under a different mechanism.
N8N_CONFIG="${POOL_DIR}/n8n/config"

for cmd in kubectl openssl; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: '${cmd}' is required" >&2
    exit 1
  fi
done

mkdir -p "${POOL_DIR}"
if [ ! -s "${KEY_FILE}" ]; then
  existing=""
  if [ -s "${N8N_CONFIG}" ] && command -v python3 >/dev/null 2>&1; then
    existing="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("encryptionKey",""))' "${N8N_CONFIG}" 2>/dev/null || true)"
  fi
  if [ -n "${existing}" ]; then
    # A database already encrypted with this key exists: adopt it instead of
    # generating a new one and locking the stored credentials out.
    echo "==> Adopting encryption key from existing ${N8N_CONFIG}"
    printf '%s' "${existing}" > "${KEY_FILE}"
  else
    echo "==> Generating new n8n encryption key at ${KEY_FILE}"
    openssl rand -base64 32 | tr -d '\n' > "${KEY_FILE}"
  fi
  chmod 600 "${KEY_FILE}"
fi

KUBECTL="kubectl --context ${KUBE_CONTEXT_NAME}"
echo "==> Installing secret ${NAMESPACE}/${SECRET_NAME} (context: ${KUBE_CONTEXT_NAME})"
${KUBECTL} create namespace "${NAMESPACE}" --dry-run=client -o yaml | ${KUBECTL} apply -f -
${KUBECTL} -n "${NAMESPACE}" create secret generic "${SECRET_NAME}" \
  --from-file=N8N_ENCRYPTION_KEY="${KEY_FILE}" \
  --from-literal=N8N_HOST="${N8N_HOST}" \
  --from-literal=N8N_PORT="${N8N_PORT}" \
  --from-literal=N8N_PROTOCOL="${N8N_PROTOCOL}" \
  --dry-run=client -o yaml | ${KUBECTL} apply -f -

echo "==> Done. n8n reads its encryption key from ${NAMESPACE}/${SECRET_NAME}."
