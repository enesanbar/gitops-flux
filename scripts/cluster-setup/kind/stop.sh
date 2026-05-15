#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="local-dind-cluster"
DOCKER_NETWORK="kind-${CLUSTER_NAME}"

echo "==> Stopping proxy containers"
docker rm -f proxy-ingress-80 proxy-ingress-443 2>/dev/null || true

echo "==> Stopping dnsmasq"
docker rm -f kind-dnsmasq 2>/dev/null || true

echo "==> Deleting kind cluster"
kind delete cluster --name "${CLUSTER_NAME}" || true

echo "==> Removing Docker network"
docker network rm "${DOCKER_NETWORK}" 2>/dev/null || true

echo "==> Done."
echo "    Note: /etc/resolver/kindcluster.dev is left in place (harmless)."
echo "    To remove it: sudo rm /etc/resolver/kindcluster.dev"
