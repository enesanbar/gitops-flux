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

# Where the data-pool-{1,2} host dirs live. Next to this script by default; a
# server keeps them on its data disk instead. An explicit value is validated
# (validate_data_root) before anything uses it.
KIND_DATA_ROOT_SET="${KIND_DATA_ROOT:+1}"
KIND_DATA_ROOT="${KIND_DATA_ROOT:-${SCRIPT_DIR}}"
export KIND_DATA_ROOT  # substituted into the config templates (extraMounts hostPath)

# Topology selection. Default: single-node (1 untainted control-plane carrying
# both storage pools). Use multi for testing scheduling / affinity / drains.
TOPOLOGY="${KIND_TOPOLOGY:-single}"
CONFIG_FILE=""

# Host interface the ingress proxies (socat) publish on. Loopback by default so
# the cluster is reachable only from this machine. Set to 0.0.0.0 (or a specific
# LAN IP) to let other machines on the network reach the ingress — see
# --expose-lan / --bind-address below.
BIND_ADDR="${KIND_BIND_ADDR:-127.0.0.1}"

# Client mode: when set, this host runs NO cluster — it only stands up dnsmasq
# so that *.kindcluster.dev resolves to a remote cluster's ingress at this IP.
# Used to drive a cluster running on another machine from this laptop.
REMOTE_HOST="${KIND_REMOTE_HOST:-}"

# --print-config: print the kind config this run would create a cluster from,
# then exit without touching Docker.
PRINT_CONFIG=0

# Server mode: the cluster runs as a long-lived service on a Linux host that
# other machines reach over the network, and the host's own configuration
# management owns dnsmasq, host DNS and sysctls. See README.md, "Server mode".
SERVER_MODE="${KIND_SERVER:-0}"
API_ADDR="0.0.0.0"
API_PORT="${KIND_API_PORT:-6443}"
API_SANS="${KIND_API_SANS:-}"
# Sized for a 16 GiB host; README.md, "Server mode", has the arithmetic.
SYSTEM_RESERVED_MEMORY="${KIND_SYSTEM_RESERVED_MEMORY:-2Gi}"
EVICTION_MEMORY_AVAILABLE="${KIND_EVICTION_MEMORY_AVAILABLE:-2Gi}"
EVICTION_NODEFS_AVAILABLE="${KIND_EVICTION_NODEFS_AVAILABLE:-10%}"

# Plain-HTTP registries the nodes' containerd may pull from, as comma-separated
# host:port. Works in any mode; a server points this at its own registry.
HTTP_REGISTRIES="${KIND_HTTP_REGISTRIES:-}"

die() {
  echo "ERROR: $*" >&2
  exit 2
}

parse_args() {
  for arg in "$@"; do
    case "${arg}" in
      --topology=*)     TOPOLOGY="${arg#*=}" ;;
      --remote-host=*)  REMOTE_HOST="${arg#*=}" ;;
      --bind-address=*) BIND_ADDR="${arg#*=}" ;;
      --expose-lan)     BIND_ADDR="0.0.0.0" ;;
      --print-config)   PRINT_CONFIG=1 ;;
      --server)         SERVER_MODE=1 ;;
      -h|--help)
        cat <<EOF
Usage: $(basename "$0") [--topology=single|multi] [--expose-lan | --bind-address=IP] [--server] [--print-config]
       $(basename "$0") --remote-host=IP

Server profiles (create a cluster on this machine):
  single  (default) 1 control-plane, both data pools mounted on it
  multi             1 control-plane + 2 workers, one data pool per worker

Exposing the ingress to other machines (server side):
  --expose-lan          bind the ingress proxies to 0.0.0.0 (whole LAN)
  --bind-address=IP     bind them to a specific host IP (e.g. this box's LAN IP)
                        Default is 127.0.0.1 (reachable only from this machine).

Client mode (no cluster; point *.${DNS_DOMAIN} at a remote cluster):
  --remote-host=IP      run dnsmasq only, resolving *.${DNS_DOMAIN} to IP.
                        Use this on a laptop to reach a cluster started with
                        --expose-lan on another machine at IP.

Server mode (a long-lived cluster other machines use; Linux):
  --server              API on 0.0.0.0:\${KIND_API_PORT} with certSANs from
                        \${KIND_API_SANS}, kubelet reserves, nodes restart
                        unless-stopped. Never runs sudo and never touches dnsmasq,
                        host DNS or sysctls: the host's own tooling owns those.

  --print-config        print the rendered kind config and exit (no Docker needed)

Env vars:
  KIND_TOPOLOGY=single|multi  alternative to --topology
  KIND_BIND_ADDR=IP           alternative to --bind-address
  KIND_REMOTE_HOST=IP         alternative to --remote-host
  KIND_SKIP_SYSCTL=1          skip the inotify limit adjustment (Linux only)
  KIND_DATA_ROOT=DIR          absolute dir holding data-pool-{1,2} (default: this script's dir)
  KIND_HTTP_REGISTRIES=h:p,.. let the nodes pull from these registries over plain HTTP
  KIND_SERVER=1               alternative to --server
  KIND_API_SANS=a,b           server mode, required: extra API certificate SANs (names or IPs)
  KIND_API_PORT=6443          server mode: host port for the API server
  KIND_SYSTEM_RESERVED_MEMORY=2Gi       server mode: kubelet systemReserved.memory
  KIND_EVICTION_MEMORY_AVAILABLE=2Gi    server mode: kubelet evictionHard memory.available
  KIND_EVICTION_NODEFS_AVAILABLE=10%    server mode: kubelet evictionHard nodefs.available
EOF
        exit 0
        ;;
    esac
  done

  case "${SERVER_MODE}" in
    0|1) ;;
    *) die "KIND_SERVER must be 0 or 1 (got '${SERVER_MODE}')" ;;
  esac
  if [ "${SERVER_MODE}" = "1" ] && [ -n "${REMOTE_HOST}" ]; then
    die "server mode runs a cluster here; --remote-host runs none. Pick one."
  fi
  # Checked here, before anything runs: client mode would otherwise start
  # dnsmasq and write host DNS instead of printing.
  if [ "${PRINT_CONFIG}" = "1" ] && [ -n "${REMOTE_HOST}" ]; then
    die "--print-config prints the config of a cluster on this host; client mode (--remote-host / KIND_REMOTE_HOST) creates none. Pick one."
  fi

  # Client mode does not create a cluster, so topology/config is irrelevant.
  if [ -n "${REMOTE_HOST}" ]; then
    return 0
  fi

  case "${TOPOLOGY}" in
    single) CONFIG_FILE="${SCRIPT_DIR}/config.single.yaml" ;;
    multi)  CONFIG_FILE="${SCRIPT_DIR}/config.multi.yaml" ;;
    *) echo "ERROR: unknown topology '${TOPOLOGY}' (expected: single | multi)" >&2; exit 2 ;;
  esac

  if [ -n "${KIND_DATA_ROOT_SET}" ]; then
    validate_data_root
  fi

  local registry
  local -a registries
  HTTP_REGISTRIES="${HTTP_REGISTRIES// /}"
  IFS=',' read -r -a registries <<< "${HTTP_REGISTRIES}"
  for registry in "${registries[@]+"${registries[@]}"}"; do
    [[ "${registry}" =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]] \
      || die "KIND_HTTP_REGISTRIES: '${registry}' is not host:port"
  done

  if [ "${SERVER_MODE}" = "1" ]; then
    validate_server_mode
  fi
}

# The data root lands in an unquoted YAML scalar (extraMounts hostPath), where a
# '#', a ': ' or a newline would change the config, so an explicit value is held
# to plain path characters. The default, this script's directory, is left alone:
# it renders exactly as it always has.
validate_data_root() {
  while [ "${KIND_DATA_ROOT}" != "/" ] && [ "${KIND_DATA_ROOT%/}" != "${KIND_DATA_ROOT}" ]; do
    KIND_DATA_ROOT="${KIND_DATA_ROOT%/}"
  done
  [[ "${KIND_DATA_ROOT}" =~ ^(/[A-Za-z0-9._-]+)+$ ]] \
    || die "KIND_DATA_ROOT must be an absolute path made of letters, digits, '.', '_', '-' and '/' (got '${KIND_DATA_ROOT}')"
}

# Server-mode values are spliced into YAML, so they are checked against a strict
# character set first. kind would reject most mistakes, but only after it has
# started creating nodes.
validate_server_mode() {
  local quantity='[0-9]+(\.[0-9]+)?(Ki|Mi|Gi|Ti|k|M|G|T)?'
  local san
  local -a sans

  API_SANS="${API_SANS// /}"
  [ -n "${API_SANS}" ] \
    || die "server mode needs KIND_API_SANS: the names and IPs remote clients use for the API. They are fixed when the cluster is created."
  IFS=',' read -r -a sans <<< "${API_SANS}"
  for san in "${sans[@]}"; do
    [[ "${san}" =~ ^[A-Za-z0-9.:-]+$ ]] || die "KIND_API_SANS: '${san}' is not a host name or IP"
  done

  [[ "${API_PORT}" =~ ^[0-9]+$ ]] && [ "${API_PORT}" -ge 1 ] && [ "${API_PORT}" -le 65535 ] \
    || die "KIND_API_PORT must be a port number (got '${API_PORT}')"
  [[ "${SYSTEM_RESERVED_MEMORY}" =~ ^${quantity}$ ]] \
    || die "KIND_SYSTEM_RESERVED_MEMORY must be a quantity like 2Gi (got '${SYSTEM_RESERVED_MEMORY}')"
  [[ "${EVICTION_MEMORY_AVAILABLE}" =~ ^(${quantity}|[0-9]+(\.[0-9]+)?%)$ ]] \
    || die "KIND_EVICTION_MEMORY_AVAILABLE must be a quantity or a percentage (got '${EVICTION_MEMORY_AVAILABLE}')"
  [[ "${EVICTION_NODEFS_AVAILABLE}" =~ ^(${quantity}|[0-9]+(\.[0-9]+)?%)$ ]] \
    || die "KIND_EVICTION_NODEFS_AVAILABLE must be a quantity or a percentage (got '${EVICTION_NODEFS_AVAILABLE}')"

  # render_config splices into the template's networking: block and appends
  # top-level keys; both assume the layout the templates have today.
  if [ "$(grep -c '^networking:$' "${CONFIG_FILE}")" != "1" ] \
     || grep -qE '^(kubeadmConfigPatches:|  apiServerAddress:|  apiServerPort:)' "${CONFIG_FILE}"; then
    die "$(basename "${CONFIG_FILE}") no longer has the layout server mode patches (one networking: block, no top-level kubeadmConfigPatches); update render_config"
  fi
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

  if [ "${SERVER_MODE}" = "1" ]; then
    echo "    WARN: inotify limits are low (max_user_watches=${cur_watches}, max_user_instances=${cur_instances})"
    echo "          and server mode leaves sysctls to the host's configuration management —"
    echo "          pods may crash with 'too many open files'"
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
    if [ "${SERVER_MODE}" = "1" ]; then
      check_api_published
    fi
  else
    # Rendered to a file first: a render failure inside <(...) would not stop
    # the script, and kind would then build a default cluster from empty input.
    RENDERED_CONFIG="$(mktemp)"
    trap 'rm -f "${RENDERED_CONFIG}"' EXIT
    render_config > "${RENDERED_CONFIG}"
    KIND_EXPERIMENTAL_DOCKER_NETWORK="${DOCKER_NETWORK}" \
      kind create cluster --config "${RENDERED_CONFIG}" --wait 60s
  fi
}

# Server mode extends the topology config instead of keeping server copies of
# it, so the node layout (image pin, pools, labels) has one source of truth and
# the default render never passes through the server code.
render_config() {
  if [ "${SERVER_MODE}" != "1" ]; then
    render_topology_config
    return
  fi
  render_topology_config | add_api_server_endpoint
  echo
  render_server_patch
}

# envsubst is restricted to ${KIND_DATA_ROOT} so any other ${...} in the
# config passes through to kind untouched.
render_topology_config() {
  # shellcheck disable=SC2016  # the literal '${KIND_DATA_ROOT}' is envsubst's filter argument
  envsubst '${KIND_DATA_ROOT}' < "${CONFIG_FILE}"
}

# kind takes the API endpoint only from its config, and the templates already
# have a networking: block (validate_server_mode checked there is one), so the
# two keys go into it rather than into a second block.
add_api_server_endpoint() {
  awk -v addr="${API_ADDR}" -v port="${API_PORT}" '
    { print }
    /^networking:$/ { printf "  apiServerAddress: \"%s\"\n  apiServerPort: %s\n", addr, port }
  '
}

render_server_patch() {
  local sans_flow="\"localhost\", \"${API_ADDR}\"" san
  local -a sans
  IFS=',' read -r -a sans <<< "${API_SANS}"
  for san in "${sans[@]}"; do
    sans_flow="${sans_flow}, \"${san}\""
  done

  # shellcheck disable=SC2016  # the literal variable list is envsubst's filter argument
  KIND_CERT_SANS="${sans_flow}" \
  KIND_SYSTEM_RESERVED_MEMORY="${SYSTEM_RESERVED_MEMORY}" \
  KIND_EVICTION_MEMORY_AVAILABLE="${EVICTION_MEMORY_AVAILABLE}" \
  KIND_EVICTION_NODEFS_AVAILABLE="${EVICTION_NODEFS_AVAILABLE}" \
    envsubst '${KIND_CERT_SANS} ${KIND_SYSTEM_RESERVED_MEMORY} ${KIND_EVICTION_MEMORY_AVAILABLE} ${KIND_EVICTION_NODEFS_AVAILABLE}' \
    < "${SCRIPT_DIR}/config.server-patch.yaml"
}

# A cluster created outside server mode keeps kind's loopback API on a random
# port; re-running in server mode cannot change that, so say so.
check_api_published() {
  local published
  published="$(docker port "${CLUSTER_NAME}-control-plane" 6443/tcp 2>/dev/null || true)"
  if ! printf '%s\n' "${published}" | grep -qx "${API_ADDR}:${API_PORT}"; then
    echo "    WARN: the existing cluster publishes its API on '${published:-nothing}', not ${API_ADDR}:${API_PORT}."
    echo "          It was not created in server mode with these settings; run stop.sh --server, then start.sh again."
  fi
}

# kind creates nodes with restart policy on-failure:1, so a host reboot would
# leave the cluster down. Applied on every run; docker update is idempotent.
set_node_restart_policy() {
  echo "==> Step 3a: Restart the kind node(s) unless stopped"
  local nodes node
  nodes="$(kind get nodes --name "${CLUSTER_NAME}")"
  [ -n "${nodes}" ] || die "kind lists no nodes for cluster ${CLUSTER_NAME}"
  for node in ${nodes}; do
    docker update --restart unless-stopped "${node}" >/dev/null
    echo "    ${node}: unless-stopped"
  done
}

# kind's node images (v0.27+) already point containerd at /etc/containerd/certs.d,
# so one hosts.toml per registry is all it takes: kind's documented
# local-registry pattern. containerd reads it at pull time, so nothing restarts.
# Written on every run because a recreated node starts without it.
configure_http_registries() {
  echo "==> Step 3b: Let the kind node(s) pull from plain-HTTP registries"
  local nodes node registry dir
  local -a registries
  nodes="$(kind get nodes --name "${CLUSTER_NAME}")"
  [ -n "${nodes}" ] || die "kind lists no nodes for cluster ${CLUSTER_NAME}"
  IFS=',' read -r -a registries <<< "${HTTP_REGISTRIES}"
  for node in ${nodes}; do
    for registry in "${registries[@]}"; do
      dir="/etc/containerd/certs.d/${registry}"
      docker exec "${node}" mkdir -p "${dir}"
      printf 'server = "http://%s"\n\n[host."http://%s"]\n  capabilities = ["pull", "resolve"]\n' \
          "${registry}" "${registry}" \
        | docker exec -i "${node}" cp /dev/stdin "${dir}/hosts.toml"
      echo "    ${node}: http://${registry}"
    done
  done
}

# kind ships kindnet with a 50Mi memory limit, below its own ~75MB binary, so the binary's pages are
# evicted and re-read from disk continuously: measured at terabytes of reads a day, and CPU-throttled
# in most periods. kind never reconciles the DaemonSet, so the fix is applied on every run, after the
# kubeconfig is exported, and is idempotent on an existing cluster.
size_kindnet() {
  kubectl --context "kind-${CLUSTER_NAME}" -n kube-system patch daemonset kindnet --type=json \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources","value":{"requests":{"cpu":"50m","memory":"64Mi"},"limits":{"cpu":"500m","memory":"200Mi"}}}]' >/dev/null
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
  if [ "${BIND_ADDR}" != "127.0.0.1" ]; then
    echo "    WARN: publishing ingress on ${BIND_ADDR}:80/443 — the cluster ingress"
    echo "          will be reachable by ANY host that can route to this machine."
    echo "          Only do this on a trusted LAN."
  fi
  docker rm -f proxy-ingress-80 proxy-ingress-443 2>/dev/null || true

  docker run -d --name proxy-ingress-80 \
    --restart unless-stopped \
    --network "${DOCKER_NETWORK}" \
    -p "${BIND_ADDR}:80:80" \
    alpine/socat \
    tcp-listen:80,fork,reuseaddr tcp-connect:"${INGRESS_VIP}":80

  docker run -d --name proxy-ingress-443 \
    --restart unless-stopped \
    --network "${DOCKER_NETWORK}" \
    -p "${BIND_ADDR}:443:443" \
    alpine/socat \
    tcp-listen:443,fork,reuseaddr tcp-connect:"${INGRESS_VIP}":443
}

start_dnsmasq() {
  echo "==> Step 5: Set up local DNS (dnsmasq)"
  # Loopback for a local cluster; the remote cluster's IP in client mode.
  local dns_target="${REMOTE_HOST:-127.0.0.1}"
  echo "    Resolving *.${DNS_DOMAIN} -> ${dns_target}"
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
    "--address=/${DNS_DOMAIN}/${dns_target}"
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
  local host="$1" expected="$2"
  case "${OS}" in
    Darwin) dscacheutil -q host -a name "${host}" 2>/dev/null | grep -qF "${expected}" ;;
    *)      getent hosts "${host}" 2>/dev/null | grep -qF "${expected}" ;;
  esac
}

smoke_check_dns() {
  echo "==> Step 7: Verify host DNS resolution (best-effort)"
  local test_host="test.${DNS_DOMAIN}"
  local expected="${REMOTE_HOST:-127.0.0.1}"
  for _ in 1 2 3; do
    if resolves_via_system_dns "${test_host}" "${expected}"; then
      echo "    ${test_host} -> ${expected}"
      return 0
    fi
    sleep 1
  done
  echo "    WARN: ${test_host} does not resolve to ${expected} via system DNS yet"
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
  echo "    Proxy: ${BIND_ADDR}:80/443 -> ${INGRESS_VIP}:80/443 (via socat)"
  if [ "${BIND_ADDR}" != "127.0.0.1" ]; then
    echo "    Ingress is exposed on ${BIND_ADDR} — from another machine, point it here with:"
    echo "      ./$(basename "$0") --remote-host=<this-machine-LAN-IP>"
  fi
  if [ "${OS}" = "Linux" ]; then
    echo "    Quick check: resolvectl query test.${DNS_DOMAIN}"
  fi
  echo ""
  echo "    Next: run scripts/flux/bootstrap.sh to set up Flux + mkcert CA, then Ingress resources will be accessible"
  echo "    Test: curl http://test.${DNS_DOMAIN} (after creating an Ingress)"
}

print_server_summary() {
  echo ""
  echo "==> Cluster is ready!  (topology: ${TOPOLOGY}, server mode)"
  echo "    API server: ${API_ADDR}:${API_PORT}, certificate SANs requested: localhost, ${API_ADDR}, ${API_SANS//,/, }"
  echo "      (SANs are fixed when the cluster is created; a re-run does not change them)"
  echo "    Ingress VIP: ${INGRESS_VIP}"
  echo "    Proxy: ${BIND_ADDR}:80/443 -> ${INGRESS_VIP}:80/443 (via socat)"
  echo "    Not touched in server mode: dnsmasq, host DNS, inotify sysctls (the host's configuration management owns them)"
  echo ""
  echo "    Remote kubeconfig: take 'kind get kubeconfig --name ${CLUSTER_NAME}' and set its server to"
  echo "      https://${API_SANS%%,*}:${API_PORT} or another SAN (README.md, \"Server mode\")"
}

print_client_summary() {
  echo ""
  echo "==> Client mode ready — no cluster runs here."
  echo "    DNS: *.${DNS_DOMAIN} -> ${REMOTE_HOST} (via dnsmasq on port ${DNS_PORT})"
  echo ""
  echo "    The remote cluster at ${REMOTE_HOST} must publish its ingress on the LAN"
  echo "    (start it there with --expose-lan or --bind-address=${REMOTE_HOST})."
  echo "    TLS: trust the remote's mkcert root CA on this machine, or expect cert warnings."
  echo "    Test: curl -k https://test.${DNS_DOMAIN}  (once an Ingress exists on the remote)"
}

# Client mode: stand up only dnsmasq + host DNS pointing at a remote cluster.
run_client_mode() {
  echo "==> Client mode: pointing *.${DNS_DOMAIN} at remote cluster ${REMOTE_HOST}"
  if ! docker info >/dev/null 2>&1; then
    echo "ERROR: cannot talk to the Docker daemon (needed to run dnsmasq)." >&2
    exit 1
  fi
  start_dnsmasq
  configure_host_dns
  smoke_check_dns
  print_client_summary
}

main() {
  parse_args "$@"

  if [ "${PRINT_CONFIG}" = "1" ]; then
    render_config
    return
  fi

  if [ -n "${REMOTE_HOST}" ]; then
    run_client_mode
    return
  fi

  echo "==> Topology: ${TOPOLOGY}  (config: $(basename "${CONFIG_FILE}"))"
  preflight
  mkdir -p "${KIND_DATA_ROOT}/data-pool-1" "${KIND_DATA_ROOT}/data-pool-2"
  create_network
  create_cluster
  merge_kubeconfig
  size_kindnet
  if [ "${SERVER_MODE}" = "1" ]; then
    set_node_restart_policy
  fi
  if [ -n "${HTTP_REGISTRIES}" ]; then
    configure_http_registries
  fi
  start_proxies
  if [ "${SERVER_MODE}" = "1" ]; then
    print_server_summary
    return
  fi
  start_dnsmasq
  configure_host_dns
  smoke_check_dns
  print_summary
}

main "$@"
