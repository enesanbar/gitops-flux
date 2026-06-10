#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="local-dind-cluster"
DOCKER_NETWORK="kind-${CLUSTER_NAME}"
NETWORK_SUBNET="172.88.0.0/16"
INGRESS_VIP="172.88.0.200"
DNS_DOMAIN="kindcluster.dev"
DNS_PORT="15353"
# Multi-arch (amd64/arm64); jpillora/dnsmasq is amd64-only and would run
# emulated on Apple Silicon and fail on arm64 Linux.
DNSMASQ_IMAGE="4km3/dnsmasq:2.90-r3"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS="$(uname -s)"
export SCRIPT_DIR  # substituted into the config templates (extraMounts hostPath)

# Topology selection. Default: single-node (1 untainted control-plane carrying
# both storage pools). Use multi for testing scheduling / affinity / drains.
TOPOLOGY="${KIND_TOPOLOGY:-single}"
CONFIG_FILE=""

parse_args() {
  for arg in "$@"; do
    case "${arg}" in
      --topology=*) TOPOLOGY="${arg#*=}" ;;
      -h|--help)
        cat <<EOF
Usage: $(basename "$0") [--topology=single|multi]

Profiles:
  single  (default) 1 control-plane, both data pools mounted on it
  multi             1 control-plane + 2 workers, one data pool per worker

Env vars:
  KIND_TOPOLOGY=single|multi  alternative to --topology
  KIND_SKIP_SYSCTL=1          skip the inotify limit adjustment (Linux only)
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
}

preflight() {
  echo "==> Step 0: Preflight checks"

  local missing=""
  local cmd
  for cmd in docker kind kubectl envsubst; do
    command -v "${cmd}" >/dev/null 2>&1 || missing="${missing} ${cmd}"
  done
  if [ -n "${missing}" ]; then
    echo "ERROR: missing required command(s):${missing}" >&2
    echo "       envsubst: 'brew install gettext' (macOS) / 'sudo apt-get install gettext-base' (Debian/Ubuntu)" >&2
    echo "       docker/kind/kubectl: see README.md prerequisites" >&2
    exit 1
  fi

  for cmd in helm flux mkcert; do
    command -v "${cmd}" >/dev/null 2>&1 \
      || echo "    WARN: '${cmd}' not found — not needed now, but scripts/flux/bootstrap.sh will need it"
  done

  if ! docker info >/dev/null 2>&1; then
    echo "ERROR: cannot talk to the Docker daemon." >&2
    case "${OS}" in
      Darwin) echo "       Is Docker Desktop running?" >&2 ;;
      Linux)
        echo "       Is the docker service running?  sudo systemctl start docker" >&2
        echo "       Permission denied? Add yourself to the docker group:" >&2
        echo "         sudo usermod -aG docker \$USER   (then log out and back in)" >&2
        ;;
    esac
    exit 1
  fi

  if [ "${OS}" = "Linux" ]; then
    ensure_inotify_limits
  fi
}

# kind on Linux commonly exhausts the default inotify limits once Flux, ingress
# and the observability stack are running, surfacing as pods crash-looping with
# "too many open files". Values from kind's known-issues page.
ensure_inotify_limits() {
  local want_watches=524288 want_instances=512
  local cur_watches cur_instances
  cur_watches="$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0)"
  cur_instances="$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo 0)"

  if [ "${cur_watches}" -ge "${want_watches}" ] && [ "${cur_instances}" -ge "${want_instances}" ]; then
    return 0
  fi

  if [ "${KIND_SKIP_SYSCTL:-0}" = "1" ]; then
    echo "    WARN: inotify limits are low (max_user_watches=${cur_watches}, max_user_instances=${cur_instances})"
    echo "          and KIND_SKIP_SYSCTL=1 is set — pods may crash with 'too many open files'"
    return 0
  fi

  # Never lower a limit the user already raised elsewhere.
  if [ "${cur_watches}" -gt "${want_watches}" ]; then want_watches="${cur_watches}"; fi
  if [ "${cur_instances}" -gt "${want_instances}" ]; then want_instances="${cur_instances}"; fi

  local conf="/etc/sysctl.d/99-kind-inotify.conf"
  local content="fs.inotify.max_user_watches = ${want_watches}
fs.inotify.max_user_instances = ${want_instances}"

  echo "    Raising inotify limits for kind: writing ${conf} (requires sudo)"
  printf '%s\n' "${content}" | sed 's/^/      /'
  if printf '%s\n' "${content}" | sudo tee "${conf}" >/dev/null \
     && sudo sysctl -p "${conf}" >/dev/null; then
    echo "    Applied (remove ${conf} to undo, KIND_SKIP_SYSCTL=1 to skip)"
  else
    echo "    WARN: could not apply inotify limits — pods may crash with 'too many open files'"
    echo "          Apply manually: sudo sysctl fs.inotify.max_user_watches=${want_watches} fs.inotify.max_user_instances=${want_instances}"
  fi
}

create_network() {
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
}

create_cluster() {
  echo "==> Step 2: Create kind cluster"
  if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    echo "    Cluster ${CLUSTER_NAME} already exists, skipping create (delete it first to switch topology)"
  else
    # envsubst is restricted to ${SCRIPT_DIR} so any other ${...} in the
    # config passes through to kind untouched.
    # shellcheck disable=SC2016  # the literal '${SCRIPT_DIR}' is envsubst's filter argument
    KIND_EXPERIMENTAL_DOCKER_NETWORK="${DOCKER_NETWORK}" \
      kind create cluster --config <(envsubst '${SCRIPT_DIR}' < "${CONFIG_FILE}") --wait 60s
  fi
}

merge_kubeconfig() {
  echo "==> Step 3: Merge kubeconfig"
  mkdir -p "${HOME}/.kube"
  if [ -f "${HOME}/.kube/config" ]; then
    cp "${HOME}/.kube/config" "${HOME}/.kube/config.bak"
  fi
  kind export kubeconfig --name "${CLUSTER_NAME}"
}

start_proxies() {
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
}

start_dnsmasq() {
  echo "==> Step 5: Set up local DNS (dnsmasq)"
  docker rm -f kind-dnsmasq 2>/dev/null || true

  docker run -d --name kind-dnsmasq \
    --restart unless-stopped \
    -p "127.0.0.1:${DNS_PORT}:53/tcp" \
    -p "127.0.0.1:${DNS_PORT}:53/udp" \
    --entrypoint dnsmasq \
    "${DNSMASQ_IMAGE}" \
    --keep-in-foreground \
    --log-queries \
    --log-facility=- \
    "--address=/${DNS_DOMAIN}/127.0.0.1"
}

configure_host_dns() {
  echo "==> Step 6: Route *.${DNS_DOMAIN} DNS to dnsmasq"
  case "${OS}" in
    Darwin) configure_host_dns_darwin ;;
    Linux)
      if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        configure_host_dns_resolved
      else
        print_manual_dns_help
      fi
      ;;
    *) print_manual_dns_help ;;
  esac
}

configure_host_dns_darwin() {
  local resolver_file="/etc/resolver/${DNS_DOMAIN}"
  local desired="nameserver 127.0.0.1
port ${DNS_PORT}"

  if [ -f "${resolver_file}" ] && [ "$(cat "${resolver_file}")" = "${desired}" ]; then
    echo "    ${resolver_file} already configured"
    return 0
  fi

  echo "    Writing ${resolver_file} (requires sudo)"
  if sudo mkdir -p /etc/resolver \
     && printf '%s\n' "${desired}" | sudo tee "${resolver_file}" >/dev/null; then
    echo "    macOS now sends *.${DNS_DOMAIN} queries to 127.0.0.1:${DNS_PORT}"
  else
    echo "    WARN: could not write ${resolver_file} — create it manually with:"
    printf '%s\n' "${desired}" | sed 's/^/      /'
  fi
}

configure_host_dns_resolved() {
  local dropin="/etc/systemd/resolved.conf.d/kindcluster-dev.conf"
  local desired="# Managed by gitops-flux/scripts/cluster-setup/kind/start.sh
[Resolve]
DNS=127.0.0.1:${DNS_PORT}
Domains=~${DNS_DOMAIN}"

  if [ -f "${dropin}" ] && [ "$(cat "${dropin}")" = "${desired}" ]; then
    echo "    ${dropin} already configured"
    return 0
  fi

  echo "    Writing ${dropin} and reloading systemd-resolved (requires sudo):"
  printf '%s\n' "${desired}" | sed 's/^/      /'
  if sudo mkdir -p /etc/systemd/resolved.conf.d \
     && printf '%s\n' "${desired}" | sudo tee "${dropin}" >/dev/null \
     && sudo systemctl reload-or-restart systemd-resolved; then
    echo "    systemd-resolved now routes *.${DNS_DOMAIN} to 127.0.0.1:${DNS_PORT} (other domains unaffected)"
  else
    echo "    WARN: could not configure systemd-resolved"
    print_manual_dns_help
  fi
}

print_manual_dns_help() {
  cat <<EOF
    Automatic host DNS setup is unavailable on this system, so *.${DNS_DOMAIN}
    will not resolve yet. The dnsmasq container answers on 127.0.0.1:${DNS_PORT};
    wire your resolver to it with one of:
      - systemd-resolved (then re-run this script):
          sudo systemctl enable --now systemd-resolved
      - NetworkManager dnsmasq mode: put 'server=/${DNS_DOMAIN}/127.0.0.1#${DNS_PORT}'
        in /etc/NetworkManager/dnsmasq.d/${DNS_DOMAIN}.conf
      - /etc/hosts entries per host (no wildcard support):
          127.0.0.1 grafana.${DNS_DOMAIN}
EOF
}

resolves_via_system_dns() {
  case "${OS}" in
    Darwin) dscacheutil -q host -a name "$1" 2>/dev/null | grep -q '127\.0\.0\.1' ;;
    *)      getent hosts "$1" 2>/dev/null | grep -q '127\.0\.0\.1' ;;
  esac
}

smoke_check_dns() {
  echo "==> Step 7: Verify host DNS resolution (best-effort)"
  local test_host="test.${DNS_DOMAIN}"
  for _ in 1 2 3; do
    if resolves_via_system_dns "${test_host}"; then
      echo "    ${test_host} -> 127.0.0.1"
      return 0
    fi
    sleep 1
  done
  echo "    WARN: ${test_host} does not resolve to 127.0.0.1 via system DNS yet"
  case "${OS}" in
    Darwin) echo "          Check: dscacheutil -q host -a name ${test_host}   and: docker logs kind-dnsmasq" ;;
    *)      echo "          Check: resolvectl query ${test_host}   and: docker logs kind-dnsmasq" ;;
  esac
}

print_summary() {
  echo ""
  echo "==> Cluster is ready!  (topology: ${TOPOLOGY})"
  echo "    Ingress VIP: ${INGRESS_VIP}"
  echo "    DNS: *.${DNS_DOMAIN} -> 127.0.0.1 (via dnsmasq on port ${DNS_PORT})"
  echo "    Proxy: 127.0.0.1:80/443 -> ${INGRESS_VIP}:80/443 (via socat)"
  if [ "${OS}" = "Linux" ]; then
    echo "    Quick check: resolvectl query test.${DNS_DOMAIN}"
  fi
  echo ""
  echo "    Next: run scripts/flux/bootstrap.sh to set up Flux + mkcert CA, then Ingress resources will be accessible"
  echo "    Test: curl http://test.${DNS_DOMAIN} (after creating an Ingress)"
}

main() {
  parse_args "$@"
  echo "==> Topology: ${TOPOLOGY}  (config: $(basename "${CONFIG_FILE}"))"
  preflight
  mkdir -p "${SCRIPT_DIR}/data-pool-1" "${SCRIPT_DIR}/data-pool-2"
  create_network
  create_cluster
  merge_kubeconfig
  start_proxies
  start_dnsmasq
  configure_host_dns
  smoke_check_dns
  print_summary
}

main "$@"
