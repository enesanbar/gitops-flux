#!/usr/bin/env bash
set -euo pipefail

# Installs the Secrets the Onyx release reads through auth.*.existingSecret
# (components/onyx/helm-release.yaml) and that the CloudNativePG Cluster uses for
# its superuser (clusters/dev-cluster/components/apps/onyx/postgres-cluster.yaml).
#
# The values are generated once and kept next to the pool data they unlock
# (scripts/cluster-setup/kind/data-pool-1/onyx-secrets/): the Postgres superuser
# password must match the PGDATA a rebuilt cluster adopts, and OpenSearch bakes
# its admin password into the security index on first boot and ignores later
# changes. Wiping the pool removes both the data and the values.
#
# Usage: install-onyx-secrets.sh [kube-context]

KUBE_CONTEXT_NAME="${1:-kind-local-dind-cluster}"
NAMESPACE="onyx"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="${SCRIPT_DIR}/../cluster-setup/kind/data-pool-1/onyx-secrets"

for cmd in kubectl openssl; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: '${cmd}' is required" >&2
    exit 1
  fi
done

# ensure_value <file> <value>: writes the value only if the file is missing, so
# existing credentials are never rotated underneath their data.
ensure_value() {
  local file="${SECRETS_DIR}/$1"
  if [ ! -s "${file}" ]; then
    echo "==> Generating ${file}"
    printf '%s' "$2" > "${file}"
    chmod 600 "${file}"
  fi
}

mkdir -p "${SECRETS_DIR}"
ensure_value postgres-password "$(openssl rand -hex 24)"
# OpenSearch rejects passwords without upper, lower, digit and special
# characters, and hex output can lack the first and last; the suffix guarantees them.
ensure_value opensearch-admin-password "$(openssl rand -hex 16)Aa1!"
ensure_value redis-password "$(openssl rand -hex 24)"
ensure_value user-auth-secret "$(openssl rand -hex 32)"

KUBECTL="kubectl --context ${KUBE_CONTEXT_NAME}"

apply_secret() {
  local name="$1"
  shift
  echo "==> Installing secret ${NAMESPACE}/${name} (context: ${KUBE_CONTEXT_NAME})"
  ${KUBECTL} -n "${NAMESPACE}" create secret generic "${name}" "$@" \
    --dry-run=client -o yaml | ${KUBECTL} apply -f -
}

${KUBECTL} create namespace "${NAMESPACE}" --dry-run=client -o yaml | ${KUBECTL} apply -f -

# CloudNativePG requires basic-auth Secrets with username/password keys; the
# chart maps the same keys to POSTGRES_USER/POSTGRES_PASSWORD.
apply_secret onyx-postgresql \
  --type=kubernetes.io/basic-auth \
  --from-literal=username=postgres \
  --from-file=password="${SECRETS_DIR}/postgres-password"

apply_secret onyx-opensearch \
  --from-literal=opensearch_admin_username=admin \
  --from-file=opensearch_admin_password="${SECRETS_DIR}/opensearch-admin-password"

apply_secret onyx-redis \
  --from-file=redis_password="${SECRETS_DIR}/redis-password"

apply_secret onyx-userauth \
  --from-file=user_auth_secret="${SECRETS_DIR}/user-auth-secret"

echo "==> Done."
