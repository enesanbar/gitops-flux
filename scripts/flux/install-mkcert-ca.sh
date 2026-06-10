#!/usr/bin/env bash
set -euo pipefail

# Installs THIS machine's mkcert CA into the cluster as the secret backing the
# 'mkcert-issuer' ClusterIssuer (clusters/dev-cluster/components/infrastructure/cert-issuer).
# The CA key pair is deliberately NOT stored in git: each machine runs this once
# per cluster so cert-manager signs with a CA the local browsers already trust.
#
# Usage: install-mkcert-ca.sh [kube-context] [--renew-all]
#   --renew-all  delete every cert-manager-issued TLS secret so certificates
#                are immediately re-issued by the (new) CA

CA_SECRET_NAME="mkcert-ca-key-pair"
CA_NAMESPACE="cert-manager"

KUBE_CONTEXT_NAME="kind-local-dind-cluster"
RENEW_ALL=0
for arg in "$@"; do
  case "${arg}" in
    --renew-all) RENEW_ALL=1 ;;
    *) KUBE_CONTEXT_NAME="${arg}" ;;
  esac
done

for cmd in mkcert kubectl; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: '${cmd}' is required" >&2
    exit 1
  fi
done

# Creates the CA on first run and registers it in the local trust stores
# (system + NSS). On Linux, browser trust needs certutil from libnss3-tools;
# mkcert warns if it's missing. May prompt for sudo.
mkcert -install

CAROOT="$(mkcert -CAROOT)"
KUBECTL="kubectl --context ${KUBE_CONTEXT_NAME}"

echo "==> Installing mkcert CA from ${CAROOT}"
echo "    as secret ${CA_NAMESPACE}/${CA_SECRET_NAME} (context: ${KUBE_CONTEXT_NAME})"
${KUBECTL} create namespace "${CA_NAMESPACE}" --dry-run=client -o yaml | ${KUBECTL} apply -f -
${KUBECTL} -n "${CA_NAMESPACE}" create secret tls "${CA_SECRET_NAME}" \
  --key "${CAROOT}/rootCA-key.pem" \
  --cert "${CAROOT}/rootCA.pem" \
  --dry-run=client -o yaml | ${KUBECTL} apply -f -

if [ "${RENEW_ALL}" = "1" ]; then
  echo "==> Deleting issued TLS secrets so cert-manager re-issues with this CA"
  ${KUBECTL} get certificate -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.spec.secretName}{"\n"}{end}' 2>/dev/null \
    | while read -r ns secret; do
        if [ -n "${ns}" ] && [ -n "${secret}" ]; then
          ${KUBECTL} -n "${ns}" delete secret "${secret}" --ignore-not-found
        fi
      done
fi

echo "==> Done. The 'mkcert-issuer' ClusterIssuer now signs with this machine's CA."
