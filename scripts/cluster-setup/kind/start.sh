#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="local-dind-cluster"
DOCKER_NETWORK="kind-${CLUSTER_NAME}"
NETWORK_SUBNET="172.88.0.0/16"
INGRESS_VIP="172.88.0.200"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Topology selection. Default: single-node (1 untainted control-plane carrying
# both storage pools). Use multi for testing scheduling / affinity / drains.
TOPOLOGY="${KIND_TOPOLOGY:-single}"
for arg in "$@"; do
  case "${arg}" in
    --topology=*) TOPOLOGY="${arg#*=}" ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--topology=single|multi]

Profiles:
  single  (default) 1 control-plane, both data pools mounted on it
  multi             1 control-plane + 2 workers, one data pool per worker

Env var KIND_TOPOLOGY=single|multi works as an alternative.
EOF
      exit 0
      ;;
  esac
done

case "${TOPOLOGY}" in
  single) CONFIG_FILE="${SCRIPT_DIR}/config.single.yaml" ;;
  multi)  CONFIG_FILE="${SCRIPT_DIR}/config.multi.yaml" ;;
  *) echo "ERROR: unknown topology '${TOPOLOGY}' (expected: single | multi)" >&2; exit 2 ;;
esac

echo "==> Topology: ${TOPOLOGY}  (config: $(basename "${CONFIG_FILE}"))"

mkdir -p "${SCRIPT_DIR}/data-pool-1" "${SCRIPT_DIR}/data-pool-2"

echo "==> Step 1: Create dedicated Docker network (if not exists)"
if ! docker network inspect "${DOCKER_NETWORK}" >/dev/null 2>&1; then
  docker network create \
    --driver bridge \
    --subnet "${NETWORK_SUBNET}" \
    "${DOCKER_NETWORK}"
  echo "    Created network ${DOCKER_NETWORK} with subnet ${NETWORK_SUBNET}"
else
  echo "    Network ${DOCKER_NETWORK} already exists"
fi

echo "==> Step 2: Create kind cluster"
export SCRIPT_DIR
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo "    Cluster ${CLUSTER_NAME} already exists, skipping create (delete it first to switch topology)"
else
  KIND_EXPERIMENTAL_DOCKER_NETWORK="${DOCKER_NETWORK}" \
    kind create cluster --config <(envsubst < "${CONFIG_FILE}") --wait 60s
fi

echo "==> Step 3: Merge kubeconfig"
kind get kubeconfig --name="${CLUSTER_NAME}" > /tmp/${CLUSTER_NAME}.yaml
KUBECONFIG=~/.kube/config:/tmp/${CLUSTER_NAME}.yaml \
  kubectl config view --flatten > /tmp/merged-kubeconfig.yaml
cp ~/.kube/config ~/.kube/config.bak
mv /tmp/merged-kubeconfig.yaml ~/.kube/config
rm -f /tmp/${CLUSTER_NAME}.yaml

echo "==> Step 4: Set up host-to-cluster traffic forwarding"
docker rm -f proxy-ingress-80 proxy-ingress-443 2>/dev/null || true

docker run -d --name proxy-ingress-80 \
  --restart unless-stopped \
  --network "${DOCKER_NETWORK}" \
  -p "127.0.0.1:80:80" \
  alpine/socat \
  tcp-listen:80,fork,reuseaddr tcp-connect:"${INGRESS_VIP}":80

docker run -d --name proxy-ingress-443 \
  --restart unless-stopped \
  --network "${DOCKER_NETWORK}" \
  -p "127.0.0.1:443:443" \
  alpine/socat \
  tcp-listen:443,fork,reuseaddr tcp-connect:"${INGRESS_VIP}":443

echo "==> Step 5: Set up local DNS (dnsmasq)"
docker rm -f kind-dnsmasq 2>/dev/null || true

docker run -d --name kind-dnsmasq \
  --restart unless-stopped \
  -p "127.0.0.1:15353:53/tcp" \
  -p "127.0.0.1:15353:53/udp" \
  jpillora/dnsmasq \
  --no-daemon \
  --log-queries \
  --address=/kindcluster.dev/127.0.0.1

if [ ! -f /etc/resolver/kindcluster.dev ]; then
  echo "    Creating /etc/resolver/kindcluster.dev (requires sudo)"
  sudo mkdir -p /etc/resolver
  sudo tee /etc/resolver/kindcluster.dev > /dev/null <<RESOLVER
nameserver 127.0.0.1
port 15353
RESOLVER
fi

echo ""
echo "==> Cluster is ready!  (topology: ${TOPOLOGY})"
echo "    Ingress VIP: ${INGRESS_VIP}"
echo "    DNS: *.kindcluster.dev -> 127.0.0.1 (via dnsmasq on port 15353)"
echo "    Proxy: 127.0.0.1:80/443 -> ${INGRESS_VIP}:80/443 (via socat)"
echo ""
echo "    Next: run bootstrap.sh to set up Flux + mkcert CA, then Ingress resources will be accessible"
echo "    Test: curl http://test.kindcluster.dev (after creating an Ingress)"
