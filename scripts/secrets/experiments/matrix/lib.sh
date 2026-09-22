# shared helpers for the GW.5 rows (sourced); prints names, lengths, statuses and timings only
set +x; set -uo pipefail
W="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
: "${SECRET_STATE_DIR:?export SECRET_STATE_DIR to the private custody directory}"
V="$W/scripts/secrets/vault.sh"; K="kubectl --context kind-local-dind-cluster"; F="flux --context kind-local-dind-cluster"
RUNS="${RUNS:-/tmp/eso-matrix-runs}"
now() { date -u +%FT%TZ; }; T0=$(date -u +%s); el() { echo "+$(( $(date -u +%s)-T0 ))s"; }
store() { $K -n "${1:-trellis}" get secretstore vault -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null; }
es() { $K -n "${1:-trellis}" get externalsecret "$2" -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null; }
esmsg() { $K -n "${1:-trellis}" get externalsecret "$2" -o jsonpath='{.status.conditions[0].message}' 2>/dev/null | cut -c1-160; }
klen() { $K -n "${1:-trellis}" get secret "$2" -o go-template="{{with index .data \"$3\"}}{{len .}}{{else}}absent{{end}}" 2>/dev/null || echo "no-secret"; }
ready() { curl -sS -o /dev/null -w '%{http_code}' https://trellis.kindcluster.dev/api/health/ready; }
sync() { $K -n "${1:-trellis}" annotate externalsecret "$2" force-sync="$(date +%s%N)" --overwrite >/dev/null; }
pods() { $K -n trellis get pods -l "app.kubernetes.io/component=$1" -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[0].ready,STATE:.status.containerStatuses[0].state.waiting.reason,START:.status.startTime' --no-headers 2>/dev/null | sed 's/  */ /g'; }
waitfor() { # waitfor <max-seconds> <cmd producing a value> <expected>
  local max=$1 exp=$3 i v; for i in $(seq 1 $((max/5))); do v=$(eval "$2"); [ "$v" = "$exp" ] && { echo "$v"; return 0; }; sleep 5; done; echo "$v(timeout)"; return 1; }
