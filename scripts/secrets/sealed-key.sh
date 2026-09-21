#!/usr/bin/env bash
set +x
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
KEY_DIR="${SECRET_STATE_DIR}/sealed-secrets"
KEYRING="${KEY_DIR}/keys.json"
mkdir -p "$KEY_DIR"; chmod 700 "$KEY_DIR"

merge() { python3 "${SECRETS_SCRIPT_DIR}/custody.py" merge "$KEYRING"; }
backup() {
  # Merge, never replace: old keys must remain available for historical Git revisions.
  k -n sealed-secrets get secrets -l sealedsecrets.bitnami.com/sealed-secrets-key -o json | merge
  echo "Sealing keyring backed up in $KEYRING (contents not printed)."
}
generate() {
  local name="$1" temporary
  temporary="$(mktemp -d "${KEY_DIR}/.generate.XXXXXX")"
  trap 'rm -rf "$temporary"' RETURN
  openssl req -x509 -nodes -newkey rsa:4096 -days 3650 \
    -subj '/CN=sealed-secrets.dev-cluster' \
    -keyout "${temporary}/tls.key" -out "${temporary}/tls.crt" 2>/dev/null
  k -n sealed-secrets create secret tls "$name" --key "${temporary}/tls.key" \
    --cert "${temporary}/tls.crt" --dry-run=client -o json | merge
  cat "${temporary}/tls.crt" | private_write "${KEY_DIR}/current.pem"
  rm -rf "$temporary"; trap - RETURN
}
restore() {
  test -s "$KEYRING" || { echo 'No keyring: restore your backup, or explicitly initialize a NEW environment.' >&2; exit 1; }
  ensure_namespace sealed-secrets
  # Validate format/conflicts before applying. Kubernetes stores no last-applied
  # annotation containing another copy of the private key.
  python3 "${SECRETS_SCRIPT_DIR}/custody.py" merge "$KEYRING" < "$KEYRING"
  k apply --server-side --field-manager=secret-bootstrap -f "$KEYRING" >/dev/null
  if [[ ! -s "${KEY_DIR}/current.pem" ]]; then
    echo 'Missing current.pem; restore the complete custody directory.' >&2; exit 1
  fi
  k -n sealed-secrets create configmap sealed-secrets-key-custody \
    --from-file=certificate.pem="${KEY_DIR}/current.pem" --dry-run=client -o yaml |
    k apply --server-side --field-manager=secret-bootstrap -f - >/dev/null
  echo 'Persisted sealing keys imported; bootstrap gate installed.'
}
case "${1:-}" in
  init)
    ensure_namespace sealed-secrets
    if [[ ! -s "$KEYRING" ]]; then
      live="$(k -n sealed-secrets get secrets -l sealedsecrets.bitnami.com/sealed-secrets-key -o json | jq '.items | length')"
      if [[ "$live" -gt 0 ]]; then
        backup
        # Preserve every live key, then fetch the certificate selected by the controller.
        kubeseal --context "$KUBE_CONTEXT" --controller-namespace sealed-secrets \
          --controller-name sealed-secrets-controller --fetch-cert | private_write "${KEY_DIR}/current.pem"
      else
        if [[ -f "${REPO_ROOT}/components/secret-example-sealed/secret.yaml" && "${2:-}" != --new-environment ]]; then
          echo 'Git already contains ciphertext but no keys exist locally or in the cluster. Restore custody; use init --new-environment only to deliberately create a different environment and reseal.' >&2; exit 1
        fi
        generate sealed-secrets-key
      fi
    fi
    restore ;;
  backup) backup ;;
  restore) restore ;;
  rotate)
    backup
    generate "sealed-secrets-key-$(date -u +%Y%m%d%H%M%S)"
    restore
    k -n sealed-secrets rollout restart deployment/sealed-secrets-controller
    k -n sealed-secrets rollout status deployment/sealed-secrets-controller --timeout=120s
    echo 'New key is durable and active. Old ciphertext remains supported; reseal via kubeseal --re-encrypt.' ;;
  *) echo 'Usage: sealed-key.sh init|backup|restore|rotate' >&2; exit 2 ;;
esac
