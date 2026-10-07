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
# Env:   KIND_DATA_ROOT   absolute dir holding data-pool-1, as for start.sh
#                         (default: scripts/cluster-setup/kind)
#        REQUIRE_EXISTING_SECRETS=1  never generate key material; a missing
#                         file stops the run before anything is written

KUBE_CONTEXT_NAME="${1:-kind-local-dind-cluster}"
NAMESPACE="onyx"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The pool root, as in start.sh: next to the kind scripts by default, or
# KIND_DATA_ROOT, which is validated only when set so the default is untouched.
KIND_DATA_ROOT_SET="${KIND_DATA_ROOT:+1}"
KIND_DATA_ROOT="${KIND_DATA_ROOT:-${SCRIPT_DIR}/../cluster-setup/kind}"
if [ -n "${KIND_DATA_ROOT_SET}" ]; then
  while [ "${KIND_DATA_ROOT}" != "/" ] && [ "${KIND_DATA_ROOT%/}" != "${KIND_DATA_ROOT}" ]; do
    KIND_DATA_ROOT="${KIND_DATA_ROOT%/}"
  done
  if ! [[ "${KIND_DATA_ROOT}" =~ ^(/[A-Za-z0-9._-]+)+$ ]]; then
    echo "ERROR: KIND_DATA_ROOT must be an absolute path made of letters, digits, '.', '_', '-' and '/' (got '${KIND_DATA_ROOT}')" >&2
    exit 1
  fi
fi
POOL_DIR="${KIND_DATA_ROOT}/data-pool-1"

# REQUIRE_EXISTING_SECRETS=1 forbids generating key material: fresh keys would
# not open data that already exists, so a missing file is a hard stop. Any
# other value is refused rather than read as "off".
case "${REQUIRE_EXISTING_SECRETS:-0}" in
  0 | 1) ;;
  *)
    echo "ERROR: REQUIRE_EXISTING_SECRETS must be 0 or 1 (got '${REQUIRE_EXISTING_SECRETS}')" >&2
    exit 1
    ;;
esac

# require_existing <file>...: with REQUIRE_EXISTING_SECRETS=1, exits before
# anything is written unless every file exists and is non-empty.
require_existing() {
  [ "${REQUIRE_EXISTING_SECRETS:-0}" = 1 ] || return 0
  local file missing=0
  for file in "$@"; do
    if [ ! -s "${file}" ]; then
      echo "ERROR: ${file} is missing or empty, and REQUIRE_EXISTING_SECRETS=1 forbids generating it" >&2
      missing=1
    fi
  done
  if [ "${missing}" -ne 0 ]; then
    echo "       Copy the existing key material into ${POOL_DIR} first. Nothing was changed." >&2
    exit 1
  fi
}

SECRETS_DIR="${POOL_DIR}/onyx-secrets"

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

require_existing "${SECRETS_DIR}/postgres-password" "${SECRETS_DIR}/opensearch-admin-password" \
  "${SECRETS_DIR}/redis-password" "${SECRETS_DIR}/user-auth-secret"
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
