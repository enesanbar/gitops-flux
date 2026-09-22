#!/usr/bin/env bash
# Experiment: cert-manager issuing from the lab Vault PKI. cert-manager 1.9 authenticates to Vault
# with a long-lived ServiceAccount token Secret (secretRef), so this creates a dedicated SA and token
# in cert-manager's namespace and a ClusterIssuer carrying this machine's public Vault CA; both are
# machine-specific, hence a script and not a Flux manifest; the Certificate that depends on the issuer
# rides with it so the Flux component stays self-reconciling.
# THREAT: the token Secret is a never-expiring API-server bearer token; anyone who can read Secrets in
# cert-manager can sign for the role's domains until it is revoked. Revocation = 'delete' below (removes
# the Secret and the ServiceAccount; the Vault role is harmless without them).
# Usage: cert-manager-vault-issuer.sh apply|delete
set +x; set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../common.sh"
CA_FILE="${SECRET_STATE_DIR}/vault/ca.crt"; test -s "$CA_FILE" || { echo 'Run prepare-local.sh first.' >&2; exit 1; }
manifest() {
cat <<YAML
apiVersion: v1
kind: ServiceAccount
metadata: {name: cert-manager-vault, namespace: cert-manager}
---
apiVersion: v1
kind: Secret
metadata:
  name: cert-manager-vault-token
  namespace: cert-manager
  annotations: {kubernetes.io/service-account.name: cert-manager-vault}
type: kubernetes.io/service-account-token
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: {name: vault-lab}
spec:
  vault:
    server: https://vault.vault.svc:8200
    path: pki-lab/sign/lab
    caBundle: $(base64 < "$CA_FILE" | tr -d '\n')
    auth:
      kubernetes:
        mountPath: /v1/auth/kubernetes
        role: pki-cert-manager
        secretRef: {name: cert-manager-vault-token, key: token}
---
# ISSUANCE through cert-manager: renewed by cert-manager on its own schedule; the Secret is cert-manager's.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: cm-leaf, namespace: secret-lab-pki}
spec:
  secretName: cm-leaf-tls
  dnsNames: [cm-leaf.kindcluster.dev]
  duration: 72h     # the Vault role's max_ttl
  renewBefore: 24h  # renewed every 48h
  privateKey: {algorithm: RSA, size: 2048}
  issuerRef: {name: vault-lab, kind: ClusterIssuer}
YAML
}
case "${1:-}" in
  apply) manifest | k apply --server-side --field-manager=secret-bootstrap -f - >/dev/null; echo 'ClusterIssuer vault-lab applied.' ;;
  delete) manifest | k delete --ignore-not-found -f - >/dev/null; echo 'ClusterIssuer vault-lab removed.' ;;
  *) echo 'Usage: cert-manager-vault-issuer.sh apply|delete' >&2; exit 2 ;;
esac
