#!/usr/bin/env bash
# The behavioural half of the parity gate, run once against each operator under test:
#   parity-checks.sh <label> --context kind-local-dind-cluster        # the lab, ESO 2.11.0
#   parity-checks.sh <label> --kubeconfig "${TMPDIR:-/tmp}/eso-parity/kubeconfig"   # the throwaway
# "kubectl apply succeeded" is not parity: a field the CRD accepts but the controller reads
# differently passes apply and fails silently, so each feature gets one observable, and every
# observable reads "ERR" rather than a plausible value when the lookup itself fails, so a broken
# kubectl call can never pass a check. Exit status is the number of failed checks.
# Mutates only secret-lab/eso/parity-<label>/*, seeded and destroyed by this run; values travel on
# stdin, never in argv. Prints names, lengths, digests and statuses, never a value.
set -uo pipefail

LABEL="${1:?label}"; shift; TARGET=("$@"); [ ${#TARGET[@]} -gt 0 ] || { echo "kubectl target args required" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../../.." && pwd)"
NS=secret-lab-eso
PREFIX="eso/parity-${LABEL}"
LAB_CONTEXT=kind-local-dind-cluster
kx() { kubectl "${TARGET[@]}" "$@"; }
vc() { "${REPO}/scripts/secrets/vault.sh" cli "$@"; }
T0=$(date -u +%s); el() { echo "+$(( $(date -u +%s)-T0 ))s"; }

# <name> <go-template>: the value, "absent" when the Secret does not exist, "ERR" on any other failure.
sfield() { local out rc err; err=$(mktemp); out=$(kx -n "$NS" get secret "$1" -o go-template="$2" 2>"$err"); rc=$?
  if [ $rc -eq 0 ]; then printf '%s' "$out"; elif grep -q NotFound "$err"; then printf absent; else printf ERR; fi; rm -f "$err"; }
# A digest, never the value: enough to see a change, useless to anyone reading the transcript.
digest() { local v; v=$(sfield "$1" "{{with index .data \"$2\"}}{{.}}{{else}}nokey{{end}}")
  case "$v" in absent|ERR|nokey) echo "$v" ;; *) printf '%s' "$v" | shasum | cut -c1-12 ;; esac; }
keys()     { sfield "$1" '{{range $k,$v := .data}}{{$k}}({{len $v}}) {{end}}'; }
keynames() { sfield "$1" '{{range $k,$v := .data}}{{$k}} {{end}}' | sed 's/ $//'; }
keycount() { local v; v=$(keynames "$1"); case "$v" in absent|ERR) echo "$v" ;; "") echo 0 ;; *) wc -w <<<"$v" | tr -d ' ' ;; esac; }
stype()    { sfield "$1" '{{.type}}'; }
owner()    { sfield "$1" '{{with .metadata.ownerReferences}}{{(index . 0).kind}}/{{(index . 0).name}}{{end}}'; }
esget() { local out; out=$(kx -n "$NS" get externalsecret "$1" -o jsonpath="$2" 2>/dev/null) && printf '%s' "$out" || printf ERR; }
esr()   { esget "$1" '{.status.conditions[0].reason}'; }
esmsg() { esget "$1" '{.status.conditions[0].message}' | cut -c1-140; }
cause() { kx -n "$NS" get events --field-selector "involvedObject.name=$1,type=Warning" --sort-by=.lastTimestamp \
  -o jsonpath='{.items[-1:].message}' 2>/dev/null | cut -c1-200; }
# waitfor <max-s> <cmd> <expected>: the trailing stamp is when the value arrived.
waitfor() { local max=$1 exp=$3 i v; for i in $(seq 1 $((max/5))); do v=$(eval "$2"); [ "$v" = "$exp" ] && { echo "$v @$(el)"; return 0; }; sleep 5; done; echo "${v:-empty}(timeout) @$(el)"; return 1; }
# waitchange <max-s> <cmd> <from>: a lookup failure is not a change.
waitchange() { local max=$1 from=$3 i v; for i in $(seq 1 $((max/5))); do v=$(eval "$2")
  case "$v" in ERR|absent|nokey|"") ;; *) [ "$v" != "$from" ] && { echo "changed @$(el)"; return 0; } ;; esac; sleep 5; done; echo "unchanged(${v}) @$(el)"; return 1; }
# can-i exits 1 when the answer is "no", so the answer is read from its output, never its status.
can_mint() { local out; out=$(kx auth can-i create "serviceaccounts${2:+/$2}" --subresource=token -n "$1" \
  --as=system:serviceaccount:external-secrets:external-secrets 2>/dev/null)
  case "$out" in yes|no) echo "$out" ;; *) echo ERR ;; esac; }

PASSES=0; FAILS=0
pass() { echo "   PASS  $*"; PASSES=$((PASSES+1)); }
fail() { echo "   FAIL  $*"; FAILS=$((FAILS+1)); }
expect() { [ "$2" = "$3" ] && pass "$1: $2" || fail "$1: got '$2', expected '$3'"; }

put1()    { vc kv put -mount=secret-lab "${PREFIX}/$1" "$2=-" >/dev/null; }   # the value on stdin
putjson() { vc kv put -mount=secret-lab "${PREFIX}/$1" - >/dev/null; }        # a JSON object on stdin
rnd()     { openssl rand -base64 "${1:-24}" | tr -d '\n'; }
ENTRIES="kek service-token composed tls doomed found/a found/b found/c"
cleanup() {
  sed -e "s/__NS__/${NS}/g" -e "s|__PREFIX__|${PREFIX}|g" "${HERE}/parity-behaviour.yaml" | kx delete --ignore-not-found -f - >/dev/null 2>&1
  local e; for e in $ENTRIES; do vc kv metadata delete -mount=secret-lab "${PREFIX}/${e}" >/dev/null 2>&1; done
  rm -f "${CA_TMP:-}"
}
trap cleanup EXIT

echo "=== ESO parity checks: ${LABEL}, $(date -u +%FT%TZ) ==="
echo "   target: ${TARGET[*]}   namespace: ${NS}   backend subtree: secret-lab/${PREFIX}"
echo "   operator: $(kx -n external-secrets get deploy external-secrets -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo ERR)"
echo "   ExternalSecret CRD versions: $(kx get crd externalsecrets.external-secrets.io -o jsonpath='{range .spec.versions[*]}{.name}(served={.served}) {end}' 2>/dev/null || echo ERR)"

echo "-- R least-privilege token minting (CONVENTIONS section 2): the operator may request a token only"
echo "   for the ServiceAccounts its namespaced Roles name"
expect "request a token for any ServiceAccount in kube-system" "$(can_mint kube-system)" no
expect "request a token for ${NS}/vault-auth, the store's own" "$(can_mint "$NS" vault-auth)" yes
expect "request a token for ${NS}/default, which no Role names" "$(can_mint "$NS" default)" no
# Why a PASS above is hygiene and not a bound: the operator must write Secrets wherever it delivers,
# and a kubernetes.io/service-account-token Secret it creates is filled in by the token controller.
secret_reach() { local out; out=$(kx auth can-i "$1" secrets -n kube-system --as=system:serviceaccount:external-secrets:external-secrets 2>/dev/null)
  case "$out" in yes|no) echo "$out" ;; *) echo ERR ;; esac; }
echo "   OBSERVED: the operator may create Secrets in kube-system: $(secret_reach create), read them: $(secret_reach get)"

echo "-- seeding secret-lab/${PREFIX}/* and applying the behaviour set with strict validation"
CA_TMP=$(mktemp); kubectl --context "$LAB_CONTEXT" -n "$NS" get cm vault-ca -o jsonpath='{.data.ca\.crt}' > "$CA_TMP"
rnd 32 | put1 kek KEK
rnd 24 | put1 service-token SERVICE_TOKEN
jq -n '{A: "alpha", B: "bravo", C: "charlie"}' | putjson composed
jq -n --rawfile crt "$CA_TMP" --rawfile key <(openssl genrsa 2048 2>/dev/null) '{"tls.crt": $crt, "tls.key": $key}' | putjson tls
rnd 16 | put1 doomed VALUE
for f in a b c; do rnd 12 | put1 "found/${f}" V; done
if sed -e "s/__NS__/${NS}/g" -e "s|__PREFIX__|${PREFIX}|g" "${HERE}/parity-behaviour.yaml" | kx apply --validate=strict -f - >/dev/null; then
  pass "all eight ExternalSecrets accepted under --validate=strict (remoteRef.version included)"
else fail "strict apply rejected the behaviour set"; fi

echo "-- P0 every object syncs"
for n in p-explicit p-pinned p-extract p-typed-tls p-createdonce p-periodic-slow p-delete-policy p-find; do
  r=$(waitfor 180 "esr ${n}" SecretSynced) && pass "${n} ${r}" || fail "${n} ${r} msg=$(esmsg "$n")"
done

echo "-- P1 shapes"
expect "p-explicit keys" "$(keynames p-explicit)" "KEK"
expect "p-pinned keys" "$(keynames p-pinned)" "KEK SERVICE_TOKEN"
expect "p-extract keys (dataFrom.extract, one entry)" "$(keynames p-extract)" "A B C"
expect "p-typed-tls type" "$(stype p-typed-tls)" "kubernetes.io/tls"
expect "p-explicit owner (creationPolicy Owner)" "$(owner p-explicit)" "ExternalSecret/p-explicit"

echo "-- P2 a new version of the key: Periodic follows; a pinned version and CreatedOnce do not"
b_explicit=$(digest p-explicit KEK); b_pinned=$(digest p-pinned KEK); b_once=$(digest p-createdonce KEK); b_slow=$(digest p-periodic-slow KEK)
echo "   digests before: explicit=${b_explicit} pinned=${b_pinned} createdonce=${b_once} periodic-slow=${b_slow}"
rnd 32 | put1 kek KEK; began=$(el); echo "   wrote kek v2 at ${began}"
r=$(waitchange 120 'digest p-explicit KEK' "$b_explicit") && pass "p-explicit followed: ${r} [write ${began}]" || fail "p-explicit did not follow: ${r}"
sleep 45   # at least one more 30s refresh for everything else
expect "p-pinned KEK after two refreshes (version pinned to 1)" "$(digest p-pinned KEK)" "$b_pinned"
expect "p-pinned still healthy" "$(esr p-pinned)" "SecretSynced"
# Force both a CreatedOnce object and its Periodic twin on the same effective interval: the twin
# following is what shows the forced sync was real, so the CreatedOnce result means something.
expect "control: p-periodic-slow has not refreshed on its own (1h interval)" "$(digest p-periodic-slow KEK)" "$b_slow"
for n in p-createdonce p-periodic-slow; do kx -n "$NS" annotate externalsecret "$n" force-sync="$(date +%s)" --overwrite >/dev/null; done
began=$(el)
r=$(waitchange 60 'digest p-periodic-slow KEK' "$b_slow") && pass "control: p-periodic-slow followed the forced sync: ${r} [sync ${began}]" \
  || fail "control: the forced sync did not reach p-periodic-slow (${r}), so the CreatedOnce check below proves nothing"
expect "p-createdonce KEK after the same forced sync" "$(digest p-createdonce KEK)" "$b_once"

echo "-- P3 the pin is per key: the same Secret's other key still refreshes"
b_token=$(digest p-pinned SERVICE_TOKEN)
rnd 24 | put1 service-token SERVICE_TOKEN; began=$(el)
r=$(waitchange 120 'digest p-pinned SERVICE_TOKEN' "$b_token") && pass "p-pinned SERVICE_TOKEN followed: ${r} [write ${began}]" || fail "p-pinned SERVICE_TOKEN did not follow: ${r}"
expect "p-pinned KEK still pinned" "$(digest p-pinned KEK)" "$b_pinned"

echo "-- P4 deletionPolicy Delete removes the Secret when its entry goes (the refused behaviour)"
vc kv metadata delete -mount=secret-lab "${PREFIX}/doomed" >/dev/null; began=$(el)
r=$(waitfor 180 'keys p-delete-policy' absent) && pass "p-delete-policy Secret gone: ${r} [delete ${began}]" || fail "p-delete-policy Secret still there: ${r}"
echo "   reason=$(esr p-delete-policy) message=$(esmsg p-delete-policy)"

echo "-- P5 deletionPolicy Retain keeps the Secret, and the ExternalSecret carries the failure"
vc kv metadata delete -mount=secret-lab "${PREFIX}/kek" >/dev/null; began=$(el)
r=$(waitfor 120 'esr p-explicit' SecretSyncedError) && pass "p-explicit ${r} [delete ${began}]" || fail "p-explicit ${r}"
expect "p-explicit Secret kept" "$(keynames p-explicit)" "KEK"
echo "   condition message: $(esmsg p-explicit)"
echo "   cause, from the latest warning event: $(cause p-explicit)"

echo "-- P6 dataFrom.find drops a removed key while reporting success (the refused behaviour)"
b_count=$(keycount p-find); echo "   before: ${b_count} keys ($(keynames p-find)) reason=$(esr p-find)"
vc kv metadata delete -mount=secret-lab "${PREFIX}/found/b" >/dev/null; began=$(el)
r=$(waitfor 120 'keycount p-find' 2); echo "   after: $(keynames p-find) reason=$(esr p-find) [delete ${began}, ${r}]"
if [ "$b_count" = 3 ] && [ "$(keycount p-find)" = 2 ] && [ "$(esr p-find)" = SecretSynced ]; then
  pass "hazard reproduced: a key vanished and the status stayed SecretSynced"
else fail "find did not behave as recorded (before=${b_count}, after=$(keycount p-find), reason=$(esr p-find))"; fi

echo "=== ${LABEL}: ${PASSES} passed, ${FAILS} failed, $(el) ==="
exit "$FAILS"
