#!/usr/bin/env bash
# Narrow, deliberate recovery exercise: only this controller's key Secrets and
# the isolated example's generated Secret are removed. Git ciphertext stays.
set +x
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
[[ "${1:-}" == --simulate-key-loss ]] || { echo 'Usage: recover-sealed.sh --simulate-key-loss' >&2; exit 2; }
"${SECRETS_SCRIPT_DIR}/sealed-key.sh" backup
test -s "${SECRET_STATE_DIR}/sealed-secrets/current.pem"
expected="$(k -n secret-lab-sealed get secret sealed-example -o json | jq -er '.data.message')"
recover() {
  "${SECRETS_SCRIPT_DIR}/sealed-key.sh" restore
  k -n sealed-secrets scale deployment/sealed-secrets-controller --replicas=1
  flux --context "$KUBE_CONTEXT" resume helmrelease sealed-secrets -n sealed-secrets
  flux --context "$KUBE_CONTEXT" resume kustomization sealed-secrets
}
flux --context "$KUBE_CONTEXT" suspend kustomization sealed-secrets
flux --context "$KUBE_CONTEXT" suspend helmrelease sealed-secrets -n sealed-secrets
trap recover EXIT
k -n sealed-secrets scale deployment/sealed-secrets-controller --replicas=0
k -n sealed-secrets wait pod -l app.kubernetes.io/name=sealed-secrets --for=delete --timeout=120s
k -n sealed-secrets delete secret -l sealedsecrets.bitnami.com/sealed-secrets-key
k -n sealed-secrets delete configmap sealed-secrets-key-custody
recover
trap - EXIT
k -n sealed-secrets rollout status deployment/sealed-secrets-controller --timeout=120s
# Force a fresh decryption of unchanged Git ciphertext, not a read of a cached Secret.
k -n secret-lab-sealed delete secret sealed-example
flux --context "$KUBE_CONTEXT" reconcile kustomization secret-example-sealed
for attempt in {1..60}; do
  actual="$(k -n secret-lab-sealed get secret sealed-example -o json 2>/dev/null | jq -r '.data.message' || true)"
  if [[ "$actual" == "$expected" ]]; then
    echo 'PASS key-loss recovery: unchanged ciphertext decrypted to the same value after private-key restoration.'
    exit 0
  fi
  sleep 2
done
echo 'Restored controller did not recreate the expected Secret.' >&2; exit 1
