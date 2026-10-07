#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="local-dind-cluster"
DOCKER_NETWORK="kind-${CLUSTER_NAME}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIND_DATA_ROOT="${KIND_DATA_ROOT:-${SCRIPT_DIR}}"  # must match what start.sh used

# Server mode (KIND_SERVER=1 or --server, as for start.sh): dnsmasq, host DNS
# and sysctls belong to the host's configuration management, so they stay.
SERVER_MODE="${KIND_SERVER:-0}"
for arg in "$@"; do
  if [ "${arg}" = "--server" ]; then SERVER_MODE=1; fi
done

echo "==> Stopping proxy containers"
docker rm -f proxy-ingress-80 proxy-ingress-443 2>/dev/null || true

if [ "${SERVER_MODE}" = "1" ]; then
  echo "==> Leaving dnsmasq alone (server mode)"
else
  echo "==> Stopping dnsmasq"
  docker rm -f kind-dnsmasq 2>/dev/null || true
fi

echo "==> Deleting kind cluster"
kind delete cluster --name "${CLUSTER_NAME}" || true

echo "==> Removing Docker network"
docker network rm "${DOCKER_NETWORK}" 2>/dev/null || true

echo "==> Done."
if [ "${SERVER_MODE}" = "1" ]; then
  echo "    Data pools are kept in ${KIND_DATA_ROOT}; pods may have written root-owned files."
  exit 0
fi
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
    echo "    To wipe them: sudo rm -rf ${KIND_DATA_ROOT}/data-pool-*"
    ;;
esac
