#!/usr/bin/env bash
set +x
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
"${SECRETS_SCRIPT_DIR}/sealed-key.sh" restore
CA_FILE="$(mkcert -CAROOT)/rootCA.pem"
test -s "$CA_FILE" || { echo 'Install the local mkcert CA first.' >&2; exit 1; }
cat "$CA_FILE" | private_write "${SECRET_STATE_DIR}/vault/ca.crt"
for namespace in secret-lab-eso secret-lab-vso trellis secret-lab-pki secret-lab-aws; do ensure_namespace "$namespace"; done
k -n secret-lab-eso create configmap vault-ca --from-file=ca.crt="$CA_FILE" --dry-run=client -o yaml |
  k apply --server-side --field-manager=secret-bootstrap -f - >/dev/null
# Application namespaces whose namespaced SecretStore validates Vault's certificate (a namespaced
# store can only read a ConfigMap in its own namespace).
for namespace in trellis secret-lab-pki secret-lab-aws; do
  k -n "$namespace" create configmap vault-ca --from-file=ca.crt="$CA_FILE" --dry-run=client -o yaml |
    k apply --server-side --field-manager=secret-bootstrap -f - >/dev/null
done
k -n secret-lab-vso create secret generic vault-ca --from-file=ca.crt="$CA_FILE" --dry-run=client -o yaml |
  k apply --server-side --field-manager=secret-bootstrap -f - >/dev/null
echo 'Sealing keys and machine-specific public CA trust restored.'
