#!/usr/bin/env bash
# The tenant store shape on ESO 0.20.3, against the parameters the lab reads through 2.11.0.
#
# A throwaway kind cluster installs chart 0.20.3 at its defaults, receives the stand-in credential
# the way a tenant receives its own, and applies components/aws-parameterstore/ and
# components/ssm-app-secrets/ unchanged. It needs AWS only, not the lab's network. Subcommands:
#   up      build it, deliver tenant key a, apply the two components, wait for them to sync
#   checks  the behaviours the lab showed, PASS/FAIL, exit status the number of failures; where both
#           clusters read the same parameters, each delivered value is compared with the lab's
#   down    remove everything up created
# The throwaway holds the stand-in's key and the example values for as long as it exists, which is
# why down is not optional. Run from a worktree with SECRET_STATE_DIR pointing at the main checkout's
# private custody.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../../.." && pwd)"
: "${SECRET_STATE_DIR:?export SECRET_STATE_DIR to the private custody directory}"
CLUSTER=eso-ssm-parity
LAB_CONTEXT=kind-local-dind-cluster
ESO_VERSION=0.20.3
STATE="${PARITY_STATE:-${TMPDIR:-/tmp}/eso-ssm-parity}"
# down removes this directory recursively, so it must be the gate's own
case "$STATE" in */eso-ssm-parity) ;; *) echo "PARITY_STATE must end in /eso-ssm-parity" >&2; exit 2 ;; esac
KCFG="${STATE}/kubeconfig"
NS=ssm-app
REFERENCE=(ssm-app ssm-app-database ssm-app-worker ssm-app-tls)

# Every call names its kubeconfig or context: the machine's default context may be a real cluster.
kp() { kubectl --kubeconfig "$KCFG" "$@"; }
kl() { kubectl --context "$LAB_CONTEXT" "$@"; }
T0=$(date +%s); el() { echo "+$(( $(date +%s) - T0 ))s"; }
waitfor() { local max=$1 exp=$3 i v; for i in $(seq 1 $((max/5))); do v=$(eval "$2"); [ "$v" = "$exp" ] && { echo "$v @$(el)"; return 0; }; sleep 5; done; echo "${v:-empty}(timeout) @$(el)"; return 1; }
esr() { "$1" -n "$2" get externalsecret "$3" -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null; }
store() { "$1" get clustersecretstore aws-parameterstore -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null; }
sync() { "$1" -n "$2" annotate externalsecret "$3" force-sync="$(date +%s%N)" --overwrite >/dev/null; }
shape() { "$1" -n "$2" get secret "$3" -o go-template='{{.type}} {{range $k,$v := .data}}{{$k}}({{len $v}}) {{end}}' 2>/dev/null; }
# digests, never values: ERR when the read fails, so a failed read cannot compare equal to another
digests() { local d; d=$("$1" -n "$2" get secret "$3" -o json 2>/dev/null) || { echo ERR; return; }
  printf '%s' "$d" | jq -r '.data | to_entries[] | .key + "=" + .value' | while IFS= read -r kv; do
    printf '%s:%s ' "${kv%%=*}" "$(printf '%s' "${kv#*=}" | shasum -a 256 | cut -c1-12)"; done; }
cause() { "$1" -n "$2" get events --field-selector "involvedObject.name=$3" --sort-by=.lastTimestamp \
  -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null | tail -1 |
  sed -E 's/arn:aws:[^ ]*/<arn>/g; s/[0-9]{12}/<account>/g; s/(RequestID|request id)[: ]+[-0-9a-f]+/\1 <id>/Ig' | cut -c1-220; }
deliver() {
  local dir="${SECRET_STATE_DIR}/aws/tenant/$1"
  kp -n external-secrets create secret generic aws-credentials \
    --from-file=aws_access_key_id="${dir}/access_key_id" --from-file=aws_secret_access_key="${dir}/secret_access_key" \
    --dry-run=client -o yaml | kp apply --server-side --field-manager=tenant-bootstrap --force-conflicts -f - >/dev/null
}
lab_aws() {
  ( unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_SESSION_TOKEN
    AWS_ACCESS_KEY_ID="$(cat "${SECRET_STATE_DIR}/aws/access_key_id")"
    AWS_SECRET_ACCESS_KEY="$(cat "${SECRET_STATE_DIR}/aws/secret_access_key")"
    AWS_REGION="$(jq -r .region "${SECRET_STATE_DIR}/aws/config.json")"
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION AWS_PAGER=""
    aws "$@" )
}
revalidate() { kp annotate clustersecretstore aws-parameterstore force-validate="$(date +%s%N)" --overwrite >/dev/null; }

up() {
  mkdir -p "$STATE"; chmod 700 "$STATE"
  UP_DONE=0
  trap '[ "$UP_DONE" = 1 ] || { echo "[$(el)] up did not finish; tearing down what it created" >&2; down; }' EXIT
  # The lab node already holds most of the VM, and the last time memory ran out a restart storm
  # sealed Vault: no second cluster above this mark.
  local used; used=$(docker stats --no-stream --format '{{.MemPerc}}' local-dind-cluster-control-plane | tr -d '%')
  awk -v u="$used" 'BEGIN { exit !(u < 75) }' || { echo "lab node at ${used}% of VM memory; not adding a cluster" >&2; exit 1; }
  echo "[$(el)] creating throwaway kind cluster ${CLUSTER} (lab node at ${used}% of VM memory)"
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --kubeconfig "$KCFG" --wait 120s >/dev/null
  # Repository config and cache of its own: with --repo, helm still reads every configured repository's cache.
  echo "[$(el)] installing external-secrets ${ESO_VERSION} at chart defaults"
  helm --kubeconfig "$KCFG" --repository-config "${STATE}/helm-repositories.yaml" --repository-cache "${STATE}/helm-cache" \
    upgrade --install external-secrets external-secrets --repo https://charts.external-secrets.io --version "$ESO_VERSION" \
    --namespace external-secrets --create-namespace --set installCRDs=true --wait --timeout 5m >/dev/null
  deliver a
  kubectl kustomize "${REPO}/components/aws-parameterstore" | kp apply --validate=strict -f - >/dev/null
  kubectl kustomize "${REPO}/components/ssm-app-secrets" | kp apply --validate=strict -f - >/dev/null
  echo "[$(el)] store: $(waitfor 120 "store kp" Valid)"
  local e; for e in "${REFERENCE[@]}"; do echo "[$(el)] ${e}: $(waitfor 120 "esr kp $NS $e" SecretSynced)"; done
  UP_DONE=1
}

checks() {
  local pass=0 fail=0 e
  check() { if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }
  echo "operator: $(kp -n external-secrets get deploy external-secrets -o jsonpath='{.spec.template.spec.containers[0].image}')"
  for e in "${REFERENCE[@]}"; do sync kl "$NS" "$e"; sync kp "$NS" "$e"; done
  sleep 10
  check "store Valid" '[ "$(store kp)" = Valid ]'
  for e in "${REFERENCE[@]}"; do
    check "$e synced" '[ "$(esr kp $NS $e)" = SecretSynced ]'
    check "$e has the lab's shape" '[ "$(shape kp $NS $e)" = "$(shape kl $NS $e)" ] && [ -n "$(shape kl $NS $e)" ]'
    check "$e carries the lab's values (digests)" '[ "$(digests kp $NS $e)" = "$(digests kl $NS $e)" ] && [ "$(digests kp $NS $e)" != ERR ]'
  done
  local latest; latest=$(lab_aws ssm describe-parameters --parameter-filters "Key=Name,Option=Equals,Values=/devops/dev-cluster/ssm-app/encryption_key" \
    --output json | jq -r '.Parameters[0].Version')
  echo "   the pinned key: both clusters deliver version 1; the parameter is at version ${latest}"
  check "the pin is tested against a parameter that has moved past it" '[ "$latest" -gt 1 ]'

  kp create namespace secret-lab-ssm-outsider --dry-run=client -o yaml | kp apply -f - >/dev/null
  cat <<EOF | kp apply -f - >/dev/null
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: {name: outsider, namespace: secret-lab-ssm-outsider}
spec:
  refreshInterval: 1h
  secretStoreRef: {name: aws-parameterstore, kind: ClusterSecretStore}
  target: {name: outsider, creationPolicy: Owner}
  data: [{secretKey: TOKEN, remoteRef: {key: /devops/dev-cluster/ssm-app/service_token}}]
EOF
  T0=$(date +%s); waitfor 60 "esr kp secret-lab-ssm-outsider outsider" SecretSyncedError >/dev/null || true
  local why; why=$(cause kp secret-lab-ssm-outsider outsider); echo "   unlisted namespace: $why"
  check "an unlisted namespace is refused by the store's condition" '[[ $why == *"denied by spec.condition"* ]]'
  kp delete namespace secret-lab-ssm-outsider --wait=false >/dev/null

  kp -n $NS get externalsecret ssm-app -o json | jq '{apiVersion, kind, metadata: {name: "ssm-app-claimant", namespace: .metadata.namespace}, spec}' | kp apply -f - >/dev/null
  # 2.11.0 reports this as reason SecretOwnedByOther; 0.20.3 as SecretSyncedError. The refusal is the
  # same, so it is asserted by its message, and the reason is printed for whoever writes the alert.
  T0=$(date +%s); waitfor 60 "esr kp $NS ssm-app-claimant" SecretSyncedError >/dev/null || true
  why=$(cause kp $NS ssm-app-claimant)
  echo "   second claimant, reason $(esr kp $NS ssm-app-claimant), condition message: $(kp -n $NS get externalsecret ssm-app-claimant -o jsonpath='{.status.conditions[0].message}')"
  echo "   event: $why"
  check "a second ExternalSecret for one Secret is refused as owned by another" '[[ $why == *"owned by another ExternalSecret"* ]]'
  sync kp $NS ssm-app; sleep 5
  check "and the first keeps serving it" '[ "$(esr kp $NS ssm-app)" = SecretSynced ]'
  kp -n $NS delete externalsecret ssm-app-claimant >/dev/null

  # The credential's bytes replaced by a key AWS does not know: the next sync must fail with it,
  # which shows the store reads the Secret on every reconcile rather than a client it cached.
  kp -n external-secrets create secret generic aws-credentials --from-literal=aws_access_key_id=AKIAIOSFODNN7INVALID \
    --from-literal=aws_secret_access_key=not-a-real-secret-key --dry-run=client -o yaml |
    kp apply --server-side --field-manager=tenant-bootstrap --force-conflicts -f - >/dev/null
  T0=$(date +%s)
  for _ in $(seq 1 12); do sync kp $NS ssm-app-worker; sleep 5; [ "$(esr kp $NS ssm-app-worker)" = SecretSyncedError ] && break; done
  why=$(cause kp $NS ssm-app-worker); echo "   unknown key @$(el): $why"
  check "a replaced credential is used on the next sync" '[[ $why == *UnrecognizedClient* || $why == *InvalidClientTokenId* ]]'
  check "the store stays Valid on a dead key" '[ "$(store kp)" = Valid ]'
  deliver a; T0=$(date +%s)
  for _ in $(seq 1 12); do sync kp $NS ssm-app-worker; sleep 5; [ "$(esr kp $NS ssm-app-worker)" = SecretSynced ] && break; done
  check "the real key back, the next sync recovers" '[ "$(esr kp $NS ssm-app-worker)" = SecretSynced ]'

  kp -n external-secrets delete secret aws-credentials >/dev/null; T0=$(date +%s)
  sync kp $NS ssm-app-tls; sleep 10; why=$(cause kp $NS ssm-app-tls)
  echo "   credential gone, store not revalidated: store $(store kp), event: $why"
  check "until it revalidates the store reads Valid while syncs fail" '[ "$(store kp)" = Valid ] && [ "$(esr kp $NS ssm-app-tls)" = SecretSyncedError ]'
  revalidate; T0=$(date +%s)
  waitfor 120 "store kp" InvalidProviderConfig >/dev/null || true
  check "without its credential Secret the store is InvalidProviderConfig" '[ "$(store kp)" = InvalidProviderConfig ]'
  sync kp $NS ssm-app-tls; sleep 10; why=$(cause kp $NS ssm-app-tls); echo "   store not ready: $why"
  check "and ExternalSecrets fail on the store, not the backend" '[[ $why == *"is not ready"* ]]'
  check "the delivered Secret is retained meanwhile" '[ "$(digests kp $NS ssm-app-tls)" = "$(digests kl $NS ssm-app-tls)" ] && [ "$(digests kp $NS ssm-app-tls)" != ERR ]'
  deliver a; revalidate; T0=$(date +%s); waitfor 120 "store kp" Valid >/dev/null || true
  sync kp $NS ssm-app-tls; sleep 10
  check "credential back: store Valid and the ExternalSecret synced" '[ "$(store kp)" = Valid ] && [ "$(esr kp $NS ssm-app-tls)" = SecretSynced ]'
  echo "passed=$pass failed=$fail"
  return "$fail"
}

down() {
  echo "[$(el)] removing ${CLUSTER} and its state"
  kind delete cluster --name "$CLUSTER" --kubeconfig "$KCFG" >/dev/null 2>&1 || true
  rm -rf "$STATE"
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER" && { echo "${CLUSTER} still exists" >&2; return 1; }
  echo "[$(el)] gone"
}

case "${1:-}" in
  up) up ;;
  checks) checks ;;
  down) down ;;
  *) echo "Usage: ssm-parity.sh up | checks | down" >&2; exit 2 ;;
esac
