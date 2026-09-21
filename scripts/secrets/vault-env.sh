#!/usr/bin/env bash
# Source this file AFTER ./scripts/secrets/vault.sh login.
# It never loads the root token. Do not enable shell tracing while sourcing.
set +x
_vault_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_vault_state="${SECRET_STATE_DIR:-${_vault_repo}/.local/secret-management/dev-cluster}/vault"
export VAULT_ADDR=https://vault.kindcluster.dev
export VAULT_CACERT="${_vault_state}/ca.crt"
unset VAULT_NAMESPACE VAULT_SKIP_VERIFY VAULT_TLS_SERVER_NAME
if [[ -s "${_vault_state}/operator-token" ]]; then
  export VAULT_TOKEN="$(cat "${_vault_state}/operator-token")"
else
  unset VAULT_TOKEN
  echo 'Run ./scripts/secrets/vault.sh login, then source this file again.' >&2
fi
unset _vault_repo _vault_state
