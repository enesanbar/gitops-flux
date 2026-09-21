#!/usr/bin/env bash
set +x
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
export VAULT_ADDR=https://vault.kindcluster.dev
export VAULT_CACERT="${SECRET_STATE_DIR}/vault/ca.crt"
unset VAULT_TOKEN VAULT_NAMESPACE VAULT_SKIP_VERIFY VAULT_TLS_SERVER_NAME
temporary="$(mktemp -d "${SECRET_STATE_DIR}/.auth-check.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
for mode in eso vso; do
  other=eso; [[ "$mode" == eso ]] && other=vso
  k -n "secret-lab-${mode}" create token vault-auth --audience=vault --duration=10m >"${temporary}/jwt"
  vault write -format=json auth/kubernetes/login "role=${mode}" "jwt=@${temporary}/jwt" >"${temporary}/login.json"
  export VAULT_TOKEN="$(jq -er '.auth.client_token' "${temporary}/login.json")"
  vault kv get "secret-lab/${mode}/example" >/dev/null
  vault token renew >/dev/null
  if vault kv get "secret-lab/${other}/example" >"${temporary}/denied" 2>&1; then
    echo "FAIL: ${mode} could read ${other}'s data" >&2; exit 1
  fi
  grep -q 'Code: 403' "${temporary}/denied"
  if vault write auth/kubernetes/login "role=${other}" "jwt=@${temporary}/jwt" >"${temporary}/denied" 2>&1; then
    echo "FAIL: ${mode} service account could authenticate as ${other}" >&2; exit 1
  fi
  grep -q 'Code: 403' "${temporary}/denied"
  vault token revoke -self >/dev/null
  unset VAULT_TOKEN
  echo "PASS ${mode}: native login, own-path read, self-renew/revoke; other path and role denied"
done
[[ "$(k auth can-i create serviceaccounts/vault-auth --subresource=token -n secret-lab-eso --as=system:serviceaccount:external-secrets:external-secrets)" == yes ]]
[[ "$(k auth can-i create serviceaccounts/default --subresource=token -n default --as=system:serviceaccount:external-secrets:external-secrets)" == no ]]
echo 'PASS ESO: TokenRequest RBAC is confined to the allowed service account'
