#!/usr/bin/env bash
# R16: a key pinned with remoteRef.version, in a Secret a reloader watches. A new version of the
# pinned key must restart nothing; a new version of an unpinned key in the same Secret must restart
# the consumer, which is the control that proves the reloader was watching at all.
# Runs in the trellis namespace because that is the one the reloader's selector covers, on its own
# entries (trellis/pin-probe-*) and its own objects, never the application's: its key-encryption
# key is the case this row stands in for and must not be the one rotated. Removes all of it on exit.
. "$(dirname "$0")/lib.sh"
NS=trellis
probe() { $K -n $NS get pods -l app=pin-probe -o jsonpath='{range .items[*]}{.metadata.name}@{.status.startTime} {end}' 2>/dev/null | sed 's/ $//'; }
refreshed() { $K -n $NS get externalsecret pin-probe -o jsonpath='{.status.refreshTime}' 2>/dev/null; }
# A digest, or ERR/nokey: a failed lookup must never hash to a stable value that reads as "unchanged".
dig() { local out; out=$($K -n $NS get secret pin-probe -o go-template="{{with index .data \"$1\"}}{{.}}{{else}}nokey{{end}}" 2>/dev/null) || { echo ERR; return; }
  [ "$out" = nokey ] && { echo nokey; return; }; printf '%s' "$out" | shasum | cut -c1-12; }
ver() { "$V" cli kv metadata get -mount=secret-lab -format=json "trellis/$1" 2>/dev/null | jq -r '.data.current_version // "ERR"'; }
same() { [ "$1" != ERR ] && [ "$1" != nokey ] && [ "$1" = "$2" ]; }
resync() { local b; b=$(refreshed); sync $NS pin-probe; for i in $(seq 1 24); do [ "$(refreshed)" != "$b" ] && return 0; sleep 5; done; return 1; }
cleanup() {
  $K -n $NS delete deployment pin-probe --ignore-not-found >/dev/null 2>&1
  $K -n $NS delete externalsecret pin-probe --ignore-not-found >/dev/null 2>&1
  for e in pin-probe-key pin-probe-cred; do "$V" cli kv metadata delete -mount=secret-lab "trellis/$e" >/dev/null 2>&1; done
}
trap cleanup EXIT
FAILS=0; ok() { echo "   PASS $*"; }; bad() { echo "   FAIL $*"; FAILS=$((FAILS+1)); }

echo "=== R16 pinned key under the reloader, $(now) ==="
openssl rand -base64 32 | tr -d '\n' | "$V" cli kv put -mount=secret-lab trellis/pin-probe-key KEY=- >/dev/null || { echo "seed failed" >&2; exit 1; }
openssl rand -base64 24 | tr -d '\n' | "$V" cli kv put -mount=secret-lab trellis/pin-probe-cred CRED=- >/dev/null || { echo "seed failed" >&2; exit 1; }
cat <<'YAML' | $K apply --validate=strict -f - >/dev/null
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: {name: pin-probe, namespace: trellis}
spec:
  refreshPolicy: Periodic
  refreshInterval: 1h
  secretStoreRef: {name: vault, kind: SecretStore}
  target: {name: pin-probe, creationPolicy: Owner, deletionPolicy: Retain}
  data:
  - secretKey: KEY
    remoteRef: {key: trellis/pin-probe-key, property: KEY, version: "1"}
  - secretKey: CRED
    remoteRef: {key: trellis/pin-probe-cred, property: CRED}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pin-probe
  namespace: trellis
  annotations: {reloader.stakater.com/auto: "true"}
spec:
  replicas: 1
  selector: {matchLabels: {app: pin-probe}}
  template:
    metadata: {labels: {app: pin-probe}}
    spec:
      automountServiceAccountToken: false
      securityContext: {runAsNonRoot: true, runAsUser: 65534, seccompProfile: {type: RuntimeDefault}}
      containers:
      - name: probe
        image: quay.io/prometheus/busybox:latest
        command: ['sh', '-c', 'while true; do sleep 3600; done']
        envFrom: [{secretRef: {name: pin-probe}}]
        securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
YAML
echo "[wait began $(el)] es -> $(waitfor 120 'es trellis pin-probe' SecretSynced)"
$K -n $NS rollout status deployment/pin-probe --timeout=120s >/dev/null && echo "   consumer ready @$(el): $(probe)"
p0=$(probe); k0=$(dig KEY); c0=$(dig CRED)

echo "-- a new version of the PINNED key"
openssl rand -base64 32 | tr -d '\n' | "$V" cli kv put -mount=secret-lab trellis/pin-probe-key KEY=- >/dev/null \
  && [ "$(ver pin-probe-key)" = 2 ] && ok "the pinned key's entry now has version 2" || bad "the write to the pinned key did not land"
began=$(el); resync && echo "   refreshed after the write [write ${began}, now $(el)]" || bad "no refresh after the forced sync"
sleep 45   # the reloader reacts to a Secret change within seconds; give it far more than that
same "$(dig KEY)" "$k0" && ok "KEY bytes unchanged" || bad "KEY changed despite the pin, or unreadable: $(dig KEY)"
[ -n "$p0" ] && [ "$(probe)" = "$p0" ] && ok "consumer not restarted: $(probe)" || bad "consumer restarted or unreadable: $(probe)"

echo "-- control: a new version of the UNPINNED key in the same Secret"
openssl rand -base64 24 | tr -d '\n' | "$V" cli kv put -mount=secret-lab trellis/pin-probe-cred CRED=- >/dev/null \
  && [ "$(ver pin-probe-cred)" = 2 ] && ok "the unpinned key's entry now has version 2" || bad "the write to the unpinned key did not land"
began=$(el); resync && echo "   refreshed after the write [write ${began}, now $(el)]" || bad "no refresh after the forced sync"
c1=$(dig CRED); [ "$c1" != ERR ] && [ "$c1" != nokey ] && [ "$c1" != "$c0" ] && ok "CRED bytes changed" || bad "CRED did not change, or unreadable: ${c1}"
r=$(waitfor 120 '[ "$(probe | wc -w | tr -d " ")" = 1 ] && [ "$(probe)" != "$p0" ] && echo replaced' replaced) \
  && ok "consumer restarted by the reloader: ${r} [write ${began}] -> $(probe)" || bad "consumer not restarted: ${r}"
same "$(dig KEY)" "$k0" && ok "KEY still pinned after the restart" || bad "KEY moved, or unreadable: $(dig KEY)"
echo "=== R16: ${FAILS} failure(s), $(el) ==="
exit "$FAILS"
