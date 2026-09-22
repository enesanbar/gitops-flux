#!/usr/bin/env bash
# E4: revocation and network-path differences between the three tenant auth mounts. Values never printed:
# the tenant JWT lives in a 0600 temp file under the private custody dir and is deleted on exit.
set +x; set -uo pipefail
cd "$(dirname "$0")/../../../.."
: "${SECRET_STATE_DIR:?export SECRET_STATE_DIR to the private custody directory}"
# TENANT_DIR holds the throwaway tenant kubeconfig and its node-ip file (never committed).
S="${TENANT_DIR:?export TENANT_DIR}"
KC=$S/kubeconfig; IP=$(cat $S/node-ip); T="kubectl --kubeconfig $KC"
export VAULT_ADDR=https://vault.kindcluster.dev VAULT_CACERT=$SECRET_STATE_DIR/vault/ca.crt
unset VAULT_TOKEN
tmp=$(mktemp -d "$SECRET_STATE_DIR/.e4.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
login() { # mount -> prints ok or the first error line
  local out; out=$(vault write -format=json "auth/$1/login" role=tenant-trellis "jwt=@$tmp/jwt" 2>&1)
  if echo "$out" | jq -e '.auth.client_token' >/dev/null 2>&1; then echo "$out" | jq -r '.auth.client_token' > "$tmp/tok"; VAULT_TOKEN=$(cat "$tmp/tok") vault token revoke -self >/dev/null 2>&1; echo "ok"; else echo "$out" | grep -vE '^\s*$|^URL|^Code|^Errors|^\*\s*$|Error making' | head -1 | cut -c1-110; fi
}
echo "E4 start=$(date -u +%FT%TZ)"
$T -n default create token vault-auth --audience=vault --duration=10m > "$tmp/jwt" && chmod 600 "$tmp/jwt"
echo "== baseline logins with a fresh 10m tenant JWT =="
for m in kubernetes-tenant jwt-tenant jwt-tenant-static; do printf '%-20s %s\n' "$m" "$(login $m)"; done
echo "== REVOCATION: delete the tenant ServiceAccount vault-auth, log in again with the same unexpired JWT =="
$T -n default delete sa vault-auth >/dev/null; sleep 3
for m in kubernetes-tenant jwt-tenant jwt-tenant-static; do printf '%-20s %s\n' "$m" "$(login $m)"; done
echo "-- and can ESO still mint a new token for its stores? (TokenRequest on a deleted SA)"
sleep 40; $T -n default get secretstore -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[0].reason} {end}'; echo
$T apply -f "$(dirname "$0")/rbac.yaml" >/dev/null; echo "-- SA recreated"
echo "== NETWORK PATH: point kubernetes_host and jwks_url at an unreachable address =="
./scripts/secrets/vault.sh tenant-auth enable "$KC" "https://172.88.255.254:6443" >/dev/null 2>&1 || echo "(enable with the unreachable url exited non-zero; continuing)"
$T -n default create token vault-auth --audience=vault --duration=10m > "$tmp/jwt"
for m in kubernetes-tenant jwt-tenant jwt-tenant-static; do t0=$(date +%s); r=$(login $m); printf '%-20s %-60s (%ss)\n' "$m" "$r" "$(( $(date +%s)-t0 ))"; done
echo "-- restore the reachable url"
./scripts/secrets/vault.sh tenant-auth enable "$KC" "https://${IP}:6443" | tail -1
for m in kubernetes-tenant jwt-tenant jwt-tenant-static; do printf '%-20s %s\n' "$m" "$(login $m)"; done
echo "E4 end=$(date -u +%FT%TZ)"
