#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="local-dind-cluster"
DOCKER_NETWORK="kind-${CLUSTER_NAME}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Stopping proxy containers"
docker rm -f proxy-ingress-80 proxy-ingress-443 2>/dev/null || true

echo "==> Stopping dnsmasq"
docker rm -f kind-dnsmasq 2>/dev/null || true

echo "==> Deleting kind cluster"
kind delete cluster --name "${CLUSTER_NAME}" || true

echo "==> Removing Docker network"
docker network rm "${DOCKER_NETWORK}" 2>/dev/null || true

echo "==> Done."
case "$(uname -s)" in
  Darwin)
    echo "    Note: /etc/resolver/kindcluster.dev is left in place (harmless)."
    echo "    To remove it: sudo rm /etc/resolver/kindcluster.dev"
    ;;
  Linux)
    echo "    Note: host DNS and sysctl config are left in place (harmless)."
    echo "    To remove them:"
    echo "      sudo rm /etc/systemd/resolved.conf.d/kindcluster-dev.conf && sudo systemctl reload-or-restart systemd-resolved"
    echo "      sudo rm /etc/sysctl.d/99-kind-inotify.conf"
    echo "    Data pools are kept; pods may have written root-owned files."
    echo "    To wipe them: sudo rm -rf ${SCRIPT_DIR}/data-pool-*"
    ;;
esac
