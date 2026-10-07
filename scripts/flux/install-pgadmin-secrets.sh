#!/usr/bin/env bash
set -euo pipefail

# Installs the two Secrets the pgAdmin deployment reads
# (components/pgadmin/deployment.yaml):
#
#   pgadmin/pgadmin-auth          PGADMIN_DEFAULT_PASSWORD, the web login.
#   pgadmin/pgadmin-db-passwords  one key per server in servers.json, read at
#                                 connect time by PasswordExecCommand.
#
# The login password lives next to pgAdmin's config database in data-pool-1:
# PGADMIN_DEFAULT_PASSWORD only creates the user on first boot, so once the
# volume is adopted that file is the only way back in.
#
# The database passwords are copied out of the live cluster rather than stored,
# because each database already owns them. They live in three different
# namespaces, which a pgAdmin pod cannot mount across, so they are assembled
# here into one Secret. Anything not found yet is skipped - pgAdmin simply
# prompts for that server - so it is safe to run this at bootstrap time and
# again once the databases are up.
#
# The Secret is mounted as a directory, so a re-run refreshes the files in
# place within about a minute and needs no pod restart.
#
# Usage: install-pgadmin-secrets.sh [kube-context]
# Env:   KIND_DATA_ROOT   absolute dir holding data-pool-1, as for start.sh
#                         (unset: scripts/cluster-setup/kind; empty is refused)
#        REQUIRE_EXISTING_SECRETS=1  never generate key material; a missing
#                         file stops the run before anything is written

KUBE_CONTEXT_NAME="${1:-kind-local-dind-cluster}"
NAMESPACE="pgadmin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The pool root: next to the kind scripts while KIND_DATA_ROOT is unset, as in
# start.sh. A set value is validated like start.sh's, and an empty one is
# refused rather than read as the default, so an empty copy-directory variable
# can't select this machine's own pool.
if [ -n "${KIND_DATA_ROOT+set}" ]; then
  if [ -z "${KIND_DATA_ROOT}" ]; then
    echo "ERROR: KIND_DATA_ROOT is set but empty; unset it to use the default pool" >&2
    exit 1
  fi
  while [ "${KIND_DATA_ROOT}" != "/" ] && [ "${KIND_DATA_ROOT%/}" != "${KIND_DATA_ROOT}" ]; do
    KIND_DATA_ROOT="${KIND_DATA_ROOT%/}"
  done
  if ! [[ "${KIND_DATA_ROOT}" =~ ^(/[A-Za-z0-9._-]+)+$ ]]; then
    echo "ERROR: KIND_DATA_ROOT must be an absolute path made of letters, digits, '.', '_', '-' and '/' (got '${KIND_DATA_ROOT}')" >&2
    exit 1
  fi
else
  KIND_DATA_ROOT="${SCRIPT_DIR}/../cluster-setup/kind"
fi
POOL_DIR="${KIND_DATA_ROOT}/data-pool-1"

# REQUIRE_EXISTING_SECRETS=1 forbids generating key material: fresh keys would
# not open data that already exists, so a missing file is a hard stop. Unset
# means 0; any other value, empty included, is refused rather than read as off.
case "${REQUIRE_EXISTING_SECRETS-0}" in
  0 | 1) ;;
  *)
    echo "ERROR: REQUIRE_EXISTING_SECRETS must be 0 or 1 (got '${REQUIRE_EXISTING_SECRETS}')" >&2
    exit 1
    ;;
esac

# require_existing <file>...: with REQUIRE_EXISTING_SECRETS=1, exits before
# anything is written unless every file exists and is non-empty.
require_existing() {
  [ "${REQUIRE_EXISTING_SECRETS-0}" = 1 ] || return 0
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

SECRETS_DIR="${POOL_DIR}/pgadmin-secrets"
ADMIN_PASSWORD_FILE="${SECRETS_DIR}/admin-password"

for cmd in kubectl openssl; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: '${cmd}' is required" >&2
    exit 1
  fi
done

KUBECTL="kubectl --context ${KUBE_CONTEXT_NAME}"

require_existing "${ADMIN_PASSWORD_FILE}"
mkdir -p "${SECRETS_DIR}"
if [ ! -s "${ADMIN_PASSWORD_FILE}" ]; then
  echo "==> Generating pgAdmin login password at ${ADMIN_PASSWORD_FILE}"
  # pgAdmin enforces a 6 character minimum and nothing else.
  printf '%s' "$(openssl rand -hex 16)" > "${ADMIN_PASSWORD_FILE}"
  chmod 600 "${ADMIN_PASSWORD_FILE}"
fi

${KUBECTL} create namespace "${NAMESPACE}" --dry-run=client -o yaml | ${KUBECTL} apply -f -

echo "==> Installing secret ${NAMESPACE}/pgadmin-auth (context: ${KUBE_CONTEXT_NAME})"
${KUBECTL} -n "${NAMESPACE}" create secret generic pgadmin-auth \
  --from-file=password="${ADMIN_PASSWORD_FILE}" \
  --dry-run=client -o yaml | ${KUBECTL} apply -f -

# read_db_password <namespace> <secret> [key]: prints the decoded value, or
# nothing if the namespace, the Secret or the key does not exist yet. Any other
# failure (no API, no access, a bad value) returns non-zero, which stops the
# script at the caller's assignment. The explicit `|| return` is needed because
# a command substitution does not inherit `set -e`.
read_db_password() {
  local ns="$1" secret="$2" key="${3:-password}" encoded
  encoded="$(${KUBECTL} -n "${ns}" get secret "${secret}" --ignore-not-found \
    -o "jsonpath={.data.${key}}")" || return 1
  [ -n "${encoded}" ] || return 0
  printf '%s' "${encoded}" | base64 --decode
}

# --from-literal, never a file: a trailing newline would be sent as part of
# the password.
ARGS=()
FOUND=()
SKIPPED=()

# onyx-pg: the generate-once file beside its PGDATA is authoritative and exists
# before the cluster does; the in-cluster Secret is the fallback.
onyx_password="$(cat "${POOL_DIR}/onyx-secrets/postgres-password" 2>/dev/null || true)"
if [ -z "${onyx_password}" ]; then
  onyx_password="$(read_db_password onyx onyx-postgresql)"
fi
if [ -n "${onyx_password}" ]; then
  ARGS+=(--from-literal=onyx-pg="${onyx_password}")
  FOUND+=(onyx-pg)
else
  SKIPPED+=("onyx-pg (no onyx-secrets/postgres-password, no onyx/onyx-postgresql)")
fi

# trellis-pg: generated by the CloudNativePG operator, so it does not exist
# until that cluster has run at least once.
trellis_password="$(read_db_password trellis trellis-pg-app)"
if [ -n "${trellis_password}" ]; then
  ARGS+=(--from-literal=trellis-pg="${trellis_password}")
  FOUND+=(trellis-pg)
else
  SKIPPED+=("trellis-pg (trellis/trellis-pg-app not created yet)")
fi

# keycloak: a plain Deployment whose POSTGRES_PASSWORD is hardcoded in
# components/keycloak/postgres-deployment.yaml. Read it from the live
# Deployment so this stays correct if that manifest ever moves to a Secret.
keycloak_password="$(${KUBECTL} -n keycloak get deploy postgres --ignore-not-found \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="POSTGRES_PASSWORD")].value}')"
if [ -n "${keycloak_password}" ]; then
  ARGS+=(--from-literal=keycloak="${keycloak_password}")
  FOUND+=(keycloak)
else
  SKIPPED+=("keycloak (keycloak/postgres Deployment not found)")
fi

echo "==> Installing secret ${NAMESPACE}/pgadmin-db-passwords (context: ${KUBE_CONTEXT_NAME})"
# `${ARGS[@]}` on an empty array trips `set -u` under bash 3.2, which is what
# /bin/bash still is on macOS.
if [ "${#ARGS[@]}" -eq 0 ]; then
  ${KUBECTL} -n "${NAMESPACE}" create secret generic pgadmin-db-passwords \
    --dry-run=client -o yaml | ${KUBECTL} apply -f -
else
  ${KUBECTL} -n "${NAMESPACE}" create secret generic pgadmin-db-passwords "${ARGS[@]}" \
    --dry-run=client -o yaml | ${KUBECTL} apply -f -
fi

echo "==> Collected: ${FOUND[*]:-none}"
for entry in "${SKIPPED[@]:-}"; do
  [ -n "${entry}" ] && echo "==> Skipped:   ${entry}"
done
if [ "${#SKIPPED[@]}" -gt 0 ] && [ -n "${SKIPPED[0]:-}" ]; then
  echo "==> Re-run this script once those databases exist; pgAdmin prompts for"
  echo "    anything missing in the meantime."
fi

echo "==> Done. Log in at https://pgadmin.kindcluster.dev as admin@kindcluster.dev"
echo "    Password: cat ${ADMIN_PASSWORD_FILE}"
