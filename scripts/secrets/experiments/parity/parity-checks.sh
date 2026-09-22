#!/usr/bin/env bash
# The behavioural half of the parity gate. "kubectl apply succeeded" is not parity: a field the
# 0.20.3 CRD accepts but the controller reads differently passes apply and fails silently, so every
# feature the conventions standardize or refuse gets one observable here.
# Reads the reference set (never writes to it) and mutates only secret-lab/parity/*.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../../.." && pwd)"
STATE="${PARITY_STATE:-${TMPDIR:-/tmp}/eso-parity}"
KCFG="${STATE}/kubeconfig"
kp() { kubectl --kubeconfig "$KCFG" "$@"; }
vc() { "${REPO}/scripts/secrets/vault.sh" cli "$@"; }
T0=$(date -u +%s); el() { echo "+$(( $(date -u +%s)-T0 ))s"; }

# Digest, never the value: enough to see a change, useless to anyone reading the log.
digest() { kp -n trellis get secret "$1" -o go-template="{{with index .data \"$2\"}}{{.}}{{else}}absent{{end}}" 2>/dev/null | shasum | cut -c1-12; }
# Answers "no-secret" once the Secret is gone - that string, not "", is what a wait matches on.
keys()   { kp -n trellis get secret "$1" -o go-template='{{range $k,$v := .data}}{{$k}}({{len $v}}) {{end}}' 2>/dev/null || echo "no-secret"; }
stype()  { kp -n trellis get secret "$1" -o jsonpath='{.type}' 2>/dev/null || echo "no-secret"; }
owner()  { kp -n trellis get secret "$1" -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}' 2>/dev/null; }
esr()    { kp -n trellis get externalsecret "$1" -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null; }
esmsg()  { kp -n trellis get externalsecret "$1" -o jsonpath='{.status.conditions[0].message}' 2>/dev/null | cut -c1-120; }
# waitfor <max-seconds> <cmd producing a value> <expected>  -- the trailing stamp is when the event
# happened; a bare $(el) on the caller's echo line would be expanded before the wait even starts.
waitfor() { local max=$1 exp=$3 i v; for i in $(seq 1 $((max/5))); do v=$(eval "$2"); [ "$v" = "$exp" ] && { echo "$v @$(el)"; return 0; }; sleep 5; done; echo "$v(timeout) @$(el)"; return 1; }
waituntil_changes() { local max=$1 cmd=$2 from=$3 i v; for i in $(seq 1 $((max/5))); do v=$(eval "$cmd"); [ "$v" != "$from" ] && { echo "changed @$(el)"; return 0; }; sleep 5; done; echo "unchanged(timeout) @$(el)"; return 1; }

echo "=== ESO 0.20.3 parity gate, $(date -u +%FT%TZ) ==="
echo "-- versions"
kp -n external-secrets get deploy external-secrets -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
kp api-resources --api-group=external-secrets.io 2>/dev/null | sed 's/^/   /'
echo "-- served CRD versions for externalsecrets"
kp get crd externalsecrets.external-secrets.io -o jsonpath='{range .spec.versions[*]}{.name}(served={.served},storage={.storage}) {end}'; echo

echo
echo "-- P1 reference set, applied byte-for-byte from components/trellis-secrets/"
echo "   trellis-secrets      status=$(waitfor 180 'esr trellis-secrets' SecretSynced)"
echo "   trellis-secrets      keys=$(keys trellis-secrets)"
echo "   trellis-secrets      type=$(stype trellis-secrets) owner=$(owner trellis-secrets)"
echo "   trellis-tls-eso      status=$(waitfor 180 'esr trellis-tls-eso' SecretSynced)"
echo "   trellis-tls-eso      keys=$(keys trellis-tls-eso) type=$(stype trellis-tls-eso)"

echo
echo "-- P2 standardized features on the mutable subtree"
for n in p-explicit p-extract p-typed-tls p-createdonce p-delete-policy p-find; do
  echo "   ${n} status=$(waitfor 180 "esr ${n}" SecretSynced) keys=$(keys "$n")"
done
echo "   p-typed-tls          type=$(stype p-typed-tls)  (expected kubernetes.io/tls)"
echo "   p-explicit           owner=$(owner p-explicit)  (expected ExternalSecret/p-explicit)"

echo
echo "-- P3 Periodic refresh follows a backend rotation; CreatedOnce does not"
before_explicit="$(digest p-explicit TRELLIS_KEK)"; before_once="$(digest p-createdonce TRELLIS_KEK)"
echo "   digests before        p-explicit=${before_explicit} p-createdonce=${before_once}"
vc kv put secret-lab/parity/kek TRELLIS_KEK="$(openssl rand -base64 32 | tr -d '\n')" >/dev/null
echo "   rotated parity/kek at $(el)"
began=$(el); echo "   p-explicit           $(waituntil_changes 180 'digest p-explicit TRELLIS_KEK' "$before_explicit")  [wait began ${began}]"
sleep 90
echo "   p-createdonce        after 90s further: $([ "$(digest p-createdonce TRELLIS_KEK)" = "$before_once" ] && echo 'unchanged (CreatedOnce held)' || echo 'CHANGED - CreatedOnce did not hold') @$(el)"

echo
echo "-- P4 deletionPolicy Delete removes the consumer's Secret when the backend entry goes"
echo "   p-delete-policy      before: keys=$(keys p-delete-policy)"
vc kv metadata delete secret-lab/parity/service-token >/dev/null
echo "   deleted parity/service-token at $(el)"
began=$(el); echo "   p-delete-policy      $(waitfor 240 'keys p-delete-policy' 'no-secret')  [wait began ${began}]"
echo "   p-delete-policy      secret now: $(kp -n trellis get secret p-delete-policy -o name 2>&1 | tail -1)"
echo "   p-delete-policy      es reason=$(esr p-delete-policy) msg=$(esmsg p-delete-policy)"

echo
echo "-- P5 deletionPolicy Retain keeps it, and the ExternalSecret is the signal that says so"
vc kv metadata delete secret-lab/parity/kek >/dev/null
echo "   deleted parity/kek at $(el)"
began=$(el); echo "   p-explicit           es reason=$(waitfor 180 'esr p-explicit' SecretSyncedError)  [wait began ${began}]"
echo "   p-explicit           msg=$(esmsg p-explicit)"
echo "   p-explicit           keys still=$(keys p-explicit)  (Retain: the consumer keeps mounting)"

echo
echo "-- P6 dataFrom.find: a key removed from the matched set disappears while the status stays green"
echo "   p-find               before: keys=$(keys p-find) reason=$(esr p-find)"
vc kv metadata delete secret-lab/parity/llm >/dev/null
echo "   deleted parity/llm at $(el)"
sleep 90
echo "   p-find               after 90s: keys=$(keys p-find) reason=$(esr p-find) @$(el)"

echo
echo "=== end, $(el) ==="
