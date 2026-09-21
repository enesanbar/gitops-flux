#!/usr/bin/env bash
set +x
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
VAULT_STATE="${SECRET_STATE_DIR}/vault"
mkdir -p "$VAULT_STATE"; chmod 700 "$VAULT_STATE"
export VAULT_ADDR=https://127.0.0.1:18200
export VAULT_CACERT="${VAULT_STATE}/ca.crt"
export VAULT_TLS_SERVER_NAME=vault.vault.svc
unset VAULT_TOKEN VAULT_NAMESPACE VAULT_SKIP_VERIFY
ACTION="${1:-}"; shift || true
case "$ACTION" in bootstrap|unseal|login|cli|snapshot) ;; *)
  echo 'Usage: vault.sh bootstrap|unseal|login|cli <vault args...>|snapshot' >&2; exit 2;; esac
test -s "$VAULT_CACERT" || { echo 'Run prepare-local.sh first.' >&2; exit 1; }
# Pod forwarding works even while sealed; the normal Service/UI stays unready.
# Refuse an occupied port, rather than talking to an unknown existing forward.
python3 - <<'PY'
import socket
with socket.socket() as s:
    s.bind(('127.0.0.1', 18200))
PY
k -n vault port-forward --address=127.0.0.1 pod/vault-0 18200:8200 >"${VAULT_STATE}/port-forward.log" 2>&1 &
FORWARD_PID=$!
trap 'kill "$FORWARD_PID" 2>/dev/null || true; wait "$FORWARD_PID" 2>/dev/null || true' EXIT
for attempt in {1..40}; do
  kill -0 "$FORWARD_PID" 2>/dev/null || { echo 'Vault port-forward failed; inspect the private port-forward.log.' >&2; exit 1; }
  if curl --silent --cacert "$VAULT_CACERT" --resolve vault.vault.svc:18200:127.0.0.1 \
    https://vault.vault.svc:18200/v1/sys/seal-status >"${VAULT_STATE}/status.json"; then break; fi
  sleep 0.5
done
jq -e 'has("initialized")' "${VAULT_STATE}/status.json" >/dev/null

unseal() {
  test -s "${VAULT_STATE}/init.json" || { echo 'Restore vault/init.json from the matching backup; never reinitialize retained data.' >&2; exit 1; }
  if [[ "$(jq -r '.sealed' "${VAULT_STATE}/status.json")" == true ]]; then
    # Vault CLI's interactive unseal requires a TTY. The API accepts JSON stdin,
    # keeping the key out of process arguments, terminal output and shell history.
    jq '{key: .unseal_keys_b64[0]}' "${VAULT_STATE}/init.json" |
      curl --fail --silent --show-error --cacert "$VAULT_CACERT" \
        --resolve vault.vault.svc:18200:127.0.0.1 -H 'Content-Type: application/json' \
        --data-binary @- https://vault.vault.svc:18200/v1/sys/unseal >"${VAULT_STATE}/status.json"
    jq -e '.sealed == false' "${VAULT_STATE}/status.json" >/dev/null
    echo 'Vault unsealed using host-only recovery material.'
  fi
}
normal_token() {
  test -s "${VAULT_STATE}/operator-token" || { echo 'Run vault.sh login first.' >&2; exit 1; }
  export VAULT_TOKEN="$(cat "${VAULT_STATE}/operator-token")"
}
case "$ACTION" in
  unseal) unseal ;;
  bootstrap)
    if [[ "$(jq -r '.initialized' "${VAULT_STATE}/status.json")" == false ]]; then
      if [[ -e "${VAULT_STATE}/init.json" ]]; then
        echo 'Vault is empty but recovery keys already exist. Restore the data/snapshot; refusing to overwrite keys.' >&2; exit 1
      fi
      # Keep pending output if init succeeds but the host operation is interrupted.
      # Never initialize twice automatically after an ambiguous response.
      if [[ -e "${VAULT_STATE}/init.pending.json" ]]; then
        echo 'An initialization attempt exists. Inspect init.pending.json before retrying.' >&2; exit 1
      fi
      vault operator init -key-shares=1 -key-threshold=1 -format=json >"${VAULT_STATE}/init.pending.json"
      jq -e '.root_token and (.unseal_keys_b64 | length == 1)' "${VAULT_STATE}/init.pending.json" >/dev/null
      cat "${VAULT_STATE}/init.pending.json" | private_write "${VAULT_STATE}/init.json"
      rm "${VAULT_STATE}/init.pending.json"
      echo 'Vault initialized; emergency root token and unseal key saved privately.'
    fi
    unseal
    export VAULT_TOKEN="$(jq -r '.root_token' "${VAULT_STATE}/init.json")"
    # Root is limited to this explicit, idempotent bootstrap operation.
    vault secrets list -format=json | jq -e 'has("secret-lab/")' >/dev/null || vault secrets enable -path=secret-lab kv-v2
    vault auth list -format=json | jq -e 'has("kubernetes/")' >/dev/null || vault auth enable kubernetes
    vault auth list -format=json | jq -e 'has("userpass/")' >/dev/null || vault auth enable userpass
    vault write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc:443 >/dev/null
    for policy in operator eso vso; do
      vault policy write "secret-lab-${policy}" "${SECRETS_SCRIPT_DIR}/vault/policies/${policy}.hcl" >/dev/null
    done
    for mode in eso vso; do
      vault write "auth/kubernetes/role/${mode}" bound_service_account_names=vault-auth \
        "bound_service_account_namespaces=secret-lab-${mode}" audience=vault \
        "token_policies=secret-lab-${mode}" token_no_default_policy=true token_ttl=10m token_max_ttl=1h >/dev/null
    done
    if [[ ! -s "${VAULT_STATE}/operator-password" ]]; then
      # Do not silently reset an existing account if its local password is missing.
      if vault read auth/userpass/users/operator >/dev/null 2>&1; then
        echo 'Existing operator account but no local password; restore it or explicitly reset the account.' >&2; exit 1
      fi
      openssl rand -hex 32 | tr -d '\n' | private_write "${VAULT_STATE}/operator-password"
    fi
    vault write auth/userpass/users/operator "password=@${VAULT_STATE}/operator-password" \
      token_policies=secret-lab-operator token_ttl=1h token_max_ttl=4h >/dev/null
    vault audit list -format=json | jq -e 'has("file/")' >/dev/null || vault audit enable file file_path=stdout
    unset VAULT_TOKEN
    echo 'Vault policies and Kubernetes/userpass auth configured. Next: vault.sh login.' ;;
  login)
    vault write -format=json auth/userpass/login/operator "password=@${VAULT_STATE}/operator-password" >"${VAULT_STATE}/login.pending.json"
    jq -e '.auth.client_token | type == "string" and length > 0' "${VAULT_STATE}/login.pending.json" >/dev/null
    jq -er '.auth.client_token' "${VAULT_STATE}/login.pending.json" | private_write "${VAULT_STATE}/operator-token"
    rm "${VAULT_STATE}/login.pending.json"
    echo 'Normal operator login saved (1h TTL, 4h maximum). Source scripts/secrets/vault-env.sh for the Vault CLI.' ;;
  cli) normal_token; vault "$@" ;;
  snapshot)
    # Snapshot export is an explicit emergency/admin action, never normal login.
    export VAULT_TOKEN="$(jq -r '.root_token' "${VAULT_STATE}/init.json")"
    path="${VAULT_STATE}/raft-$(date -u +%Y%m%dT%H%M%SZ).snap"
    vault operator raft snapshot save "${path}.pending"
    vault operator raft snapshot inspect "${path}.pending" >/dev/null
    mv "${path}.pending" "$path"; chmod 600 "$path"
    unset VAULT_TOKEN
    echo "Verified snapshot saved to $path" ;;
esac
