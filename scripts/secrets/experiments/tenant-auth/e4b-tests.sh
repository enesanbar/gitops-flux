#!/usr/bin/env bash
set +x; set -uo pipefail
cd /Users/enesanbar/workspace/gitops-flux/.claude/worktrees/task-0716
export SECRET_STATE_DIR=/Users/enesanbar/workspace/gitops-flux/.local/secret-management/dev-cluster
S=/private/tmp/claude-501/-Users-enesanbar-workspace-namecheap-trellis/1ab30766-ed5e-4fa8-8d64-890416384a88/scratchpad/p2gw
KC=$S/tenant/kubeconfig; T="kubectl --kubeconfig $KC"
export VAULT_ADDR=https://vault.kindcluster.dev VAULT_CACERT=$SECRET_STATE_DIR/vault/ca.crt; unset VAULT_TOKEN
tmp=$(mktemp -d "$SECRET_STATE_DIR/.e4b.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
login() { local out; out=$(vault write -format=json "auth/$1/login" role=tenant-trellis "jwt=@$tmp/jwt" 2>&1); if echo "$out" | jq -e '.auth.client_token' >/dev/null 2>&1; then VAULT_TOKEN=$(echo "$out" | jq -r .auth.client_token) vault token revoke -self >/dev/null 2>&1; echo ok; else echo "$out" | grep -vE '^\s*$|^URL|^Code|^Errors|Error making' | head -1 | cut -c1-100; fi; }
tokenreview() { # what the tenant API server itself says about the JWT (authenticated true/false + error)
  python3 - "$tmp/jwt" > "$tmp/tr.json" <<'PY'
import json,sys; print(json.dumps({"apiVersion":"authentication.k8s.io/v1","kind":"TokenReview","spec":{"token":open(sys.argv[1]).read().strip(),"audiences":["vault"]}}))
PY
  $T create -f "$tmp/tr.json" -o jsonpath='authenticated={.status.authenticated} user={.status.user.username} error={.status.error}' 2>&1 | cut -c1-140; echo
}
echo "E4b start=$(date -u +%FT%TZ)"
$T -n default create token vault-auth --audience=vault --duration=15m > "$tmp/jwt"; chmod 600 "$tmp/jwt"
echo "== baseline =="; printf 'tenant TokenReview: '; tokenreview
echo "== delete SA vault-auth, then poll TokenReview and the three logins =="
$T -n default delete sa vault-auth >/dev/null
for wait in 2 15 45 90; do sleep "$wait"; printf -- '-- +%ss after deletion: TokenReview: ' "$wait"; tokenreview; for m in kubernetes-tenant jwt-tenant jwt-tenant-static; do printf '   %-20s %s\n' "$m" "$(login $m)"; done; done
$T apply -f $S/tenant/rbac.yaml >/dev/null; echo "-- SA recreated (its UID changed; the old JWT carries the old UID)"
sleep 5; printf 'TokenReview with the OLD jwt after recreation: '; tokenreview; printf '   %-20s %s\n' kubernetes-tenant "$(login kubernetes-tenant)"
echo "== RUNTIME NETWORK OUTAGE: docker pause the tenant node (API server unreachable), fresh-JWT logins =="
$T -n default create token vault-auth --audience=vault --duration=15m > "$tmp/jwt"
docker pause tenant-lab-control-plane >/dev/null; sleep 3
for m in kubernetes-tenant jwt-tenant jwt-tenant-static; do t0=$(date +%s); r=$(login $m); printf '   %-20s %-50s (%ss)\n' "$m" "$r" "$(( $(date +%s)-t0 ))"; done
docker unpause tenant-lab-control-plane >/dev/null; sleep 5
echo "-- unpaused:"; for m in kubernetes-tenant jwt-tenant jwt-tenant-static; do printf '   %-20s %s\n' "$m" "$(login $m)"; done
echo "-- tenant stores after the outage:"; sleep 20; $T -n default get secretstore -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[0].reason} {end}'; echo
echo "E4b end=$(date -u +%FT%TZ)"
