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
case "$ACTION" in bootstrap|unseal|login|cli|snapshot|tenant-auth|pki) ;; *)
  echo 'Usage: vault.sh bootstrap|unseal|login|cli <vault args...>|snapshot|tenant-auth enable <kubeconfig> <api-url>|disable [<kubeconfig>]|pki' >&2; exit 2;; esac
test -s "$VAULT_CACERT" || { echo 'Run prepare-local.sh first.' >&2; exit 1; }
# Pod forwarding works even while sealed; the normal Service/UI stays unready.
# Refuse an occupied port, rather than talking to an unknown existing forward.
python3 - <<'PY'
import socket
with socket.socket() as s:
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(('127.0.0.1', 18200))
PY
kubectl --context "$KUBE_CONTEXT" -n vault port-forward --address=127.0.0.1 pod/vault-0 18200:8200 >"${VAULT_STATE}/port-forward.log" 2>&1 &
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
tenant_auth_enable() { # <kubeconfig> <api-url>
  local kubeconfig="$1" api_url="$2" work issuer role_args
  work="$(mktemp -d "${VAULT_STATE}/.tenant-auth.XXXXXX")"; trap 'rm -rf "$work"' RETURN
  kubectl --kubeconfig "$kubeconfig" config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d >"${work}/ca.pem"
  kubectl --kubeconfig "$kubeconfig" get --raw /openid/v1/jwks >"${work}/jwks.json"
  python3 - "${work}/jwks.json" >"${work}/pubkeys.pem" <<'PYX'
import json, sys, base64
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization
def b64(s): return int.from_bytes(base64.urlsafe_b64decode(s + "=" * (-len(s) % 4)), "big")
for k in json.load(open(sys.argv[1]))["keys"]:
    pub = rsa.RSAPublicNumbers(b64(k["e"]), b64(k["n"])).public_key()
    sys.stdout.write(pub.public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo).decode())
PYX
  issuer="$(kubectl --kubeconfig "$kubeconfig" get --raw /.well-known/openid-configuration | jq -r .issuer)"
  # A Vault outside the tenant has no identity the tenant API server accepts for TokenReview, and a
  # client token bound to audience "vault" is not a bearer token there either, so the tenant issues a
  # long-lived reviewer token that this Vault holds: the key-distribution cost of this method.
  kubectl --kubeconfig "$kubeconfig" apply -f "${SECRETS_SCRIPT_DIR}/experiments/tenant-auth/reviewer.yaml" >/dev/null
  for attempt in {1..20}; do
    kubectl --kubeconfig "$kubeconfig" -n kube-system get secret vault-token-reviewer -o go-template='{{index .data "token"}}' 2>/dev/null | grep -q . && break; sleep 1
  done
  role_args=(bound_audiences=vault token_policies=secret-lab-tenant-probe token_no_default_policy=true token_ttl=10m token_max_ttl=1h)
  vault auth list -format=json | jq -e 'has("kubernetes-tenant/")' >/dev/null || vault auth enable -path=kubernetes-tenant kubernetes
  kubectl --kubeconfig "$kubeconfig" -n kube-system get secret vault-token-reviewer -o go-template='{{index .data "token"}}' | base64 -d |
    vault write auth/kubernetes-tenant/config "kubernetes_host=${api_url}" "kubernetes_ca_cert=@${work}/ca.pem" \
      disable_local_ca_jwt=true token_reviewer_jwt=- >/dev/null
  vault write auth/kubernetes-tenant/role/tenant-probe bound_service_account_names=vault-auth \
    bound_service_account_namespaces=default audience=vault token_policies=secret-lab-tenant-probe \
    token_no_default_policy=true token_ttl=10m token_max_ttl=1h >/dev/null
  vault auth list -format=json | jq -e 'has("jwt-tenant/")' >/dev/null || vault auth enable -path=jwt-tenant jwt
  vault write auth/jwt-tenant/config "jwks_url=${api_url}/openid/v1/jwks" "jwks_ca_pem=@${work}/ca.pem" "bound_issuer=${issuer}" >/dev/null
  vault write auth/jwt-tenant/role/tenant-probe role_type=jwt user_claim=sub \
    bound_subject=system:serviceaccount:default:vault-auth "${role_args[@]}" >/dev/null
  vault auth list -format=json | jq -e 'has("jwt-tenant-static/")' >/dev/null || vault auth enable -path=jwt-tenant-static jwt
  vault write auth/jwt-tenant-static/config "jwt_validation_pubkeys=@${work}/pubkeys.pem" "bound_issuer=${issuer}" >/dev/null
  vault write auth/jwt-tenant-static/role/tenant-probe role_type=jwt user_claim=sub \
    bound_subject=system:serviceaccount:default:vault-auth "${role_args[@]}" >/dev/null
  echo "Tenant auth mounts enabled: kubernetes-tenant, jwt-tenant, jwt-tenant-static (issuer ${issuer}); tenant roles read secret-lab/tenant-probe only."
}
tenant_auth_disable() { # [<kubeconfig>]  disables the mounts; with a kubeconfig also removes the tenant-side reviewer objects
  local m
  for m in kubernetes-tenant jwt-tenant jwt-tenant-static; do
    vault auth list -format=json | jq -e "has(\"${m}/\")" >/dev/null && vault auth disable "$m" >/dev/null || true
  done
  if [[ -n "${1:-}" ]]; then
    kubectl --kubeconfig "$1" delete -f "${SECRETS_SCRIPT_DIR}/experiments/tenant-auth/reviewer.yaml" --ignore-not-found >/dev/null || true
  fi
  echo 'Tenant auth mounts disabled.'
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
    for policy in operator eso vso trellis trellis-app tenant-probe; do
      vault policy write "secret-lab-${policy}" "${SECRETS_SCRIPT_DIR}/vault/policies/${policy}.hcl" >/dev/null
    done
    for mode in eso vso; do
      vault write "auth/kubernetes/role/${mode}" bound_service_account_names=vault-auth \
        "bound_service_account_namespaces=secret-lab-${mode}" audience=vault \
        "token_policies=secret-lab-${mode}" token_no_default_policy=true token_ttl=10m token_max_ttl=1h >/dev/null
    done
    # Application roles: <role>:<namespace>:<service account>:<policy>. The store role is
    # what ESO logs in with; the app role is what the process itself may use (its documented command-based key source).
    for spec in trellis:trellis:vault-auth:secret-lab-trellis trellis-app:trellis:trellis:secret-lab-trellis-app; do
      IFS=: read -r role ns sa policy <<<"$spec"
      vault write "auth/kubernetes/role/${role}" "bound_service_account_names=${sa}" \
        "bound_service_account_namespaces=${ns}" audience=vault \
        "token_policies=${policy}" token_no_default_policy=true token_ttl=10m token_max_ttl=1h >/dev/null
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
  pki)
    # Experiment: in-cluster issuance. A lab-only PKI mount with an internal root; two policies let
    # ESO's generator and cert-manager's Vault issuer request leaf certificates and nothing else.
    # Root is used for mount, role and policy administration only, as in bootstrap.
    export VAULT_TOKEN="$(jq -r '.root_token' "${VAULT_STATE}/init.json")"
    vault secrets list -format=json | jq -e 'has("pki-lab/")' >/dev/null || vault secrets enable -path=pki-lab pki
    vault secrets tune -max-lease-ttl=8760h pki-lab >/dev/null
    if ! vault read -format=json pki-lab/cert/ca 2>/dev/null | jq -e '.data.certificate | length > 0' >/dev/null; then
      vault write -format=json pki-lab/root/generate/internal common_name="secret-lab root CA" ttl=8760h >/dev/null
    fi
    vault write pki-lab/config/urls issuing_certificates=https://vault.vault.svc:8200/v1/pki-lab/ca \
      crl_distribution_points=https://vault.vault.svc:8200/v1/pki-lab/crl >/dev/null
    vault write pki-lab/roles/lab allowed_domains=kindcluster.dev allow_subdomains=true allow_bare_domains=false \
      key_type=rsa key_bits=2048 ttl=1h max_ttl=72h >/dev/null
    for policy in pki-eso pki-cert-manager; do
      vault policy write "secret-lab-${policy}" "${SECRETS_SCRIPT_DIR}/vault/policies/${policy}.hcl" >/dev/null
    done
    vault write auth/kubernetes/role/pki-eso bound_service_account_names=vault-auth \
      bound_service_account_namespaces=secret-lab-pki audience=vault token_policies=secret-lab-pki-eso \
      token_no_default_policy=true token_ttl=10m token_max_ttl=1h >/dev/null
    # cert-manager 1.9 authenticates with a long-lived ServiceAccount token Secret, which carries the API
    # server audience, so this role sets no audience.
    vault write auth/kubernetes/role/pki-cert-manager bound_service_account_names=cert-manager-vault \
      bound_service_account_namespaces=cert-manager token_policies=secret-lab-pki-cert-manager \
      token_no_default_policy=true token_ttl=10m token_max_ttl=1h >/dev/null
    unset VAULT_TOKEN
    echo 'Lab PKI ready: mount pki-lab, role lab, Kubernetes-auth roles pki-eso and pki-cert-manager.' ;;
  tenant-auth)
    # Experiment: a second cluster authenticates to this Vault the way a tenant would reach a platform
    # Vault. Three mounts side by side so their operational differences can be measured:
    #   kubernetes-tenant  TokenReview against the tenant API server (needs reach + a tenant-issued reviewer token)
    #   jwt-tenant         JWKS fetched from the tenant API server (needs reach at setup; keys cached afterwards)
    #   jwt-tenant-static  public keys copied once (no reach at all; no revocation before token expiry)
    # Root is used the way bootstrap uses it: mount and role administration only. The tenant roles
    # read ONE purpose-only entry (secret-lab/tenant-probe), never an application's subtree.
    sub="${1:-}"; shift || true
    export VAULT_TOKEN="$(jq -r '.root_token' "${VAULT_STATE}/init.json")"
    case "$sub" in
      enable) tenant_auth_enable "${1:?kubeconfig}" "${2:?tenant API URL reachable from the Vault pod}" ;;
      disable) tenant_auth_disable "${1:-}" ;;
      *) echo 'Usage: vault.sh tenant-auth enable <kubeconfig> <api-url> | disable [<kubeconfig>]' >&2; exit 2 ;;
    esac
    unset VAULT_TOKEN ;;
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
