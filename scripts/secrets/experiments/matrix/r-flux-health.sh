#!/usr/bin/env bash
# Does the ssm-app-secrets group wait for the operator? Its Flux Kustomization carries healthCheckExprs
# (Ready, and the synced generation) because kstatus alone reads a status-less ExternalSecret as ready
# and keeps a stale Ready after a spec change. With the operator stopped:
#   H1  an ExternalSecret the operator has never seen (deleted, re-applied by Flux)
#   H2  an ExternalSecret whose spec moved past the generation the operator last synced
# each must leave the group not Ready, and the group must turn Ready once the operator is back.
# Mutates the lab: the operator runs at zero replicas for a few minutes (no ExternalSecret refreshes,
# every delivered Secret stays, and no ExternalSecret can finish deleting), and ssm-app-worker's Secret
# is garbage-collected during H1. The exit trap brings the operator back and has Flux re-apply the
# reference.
source "$(dirname "$0")/lib.sh"
NS=ssm-app; KS=ssm-app-secrets
ks() { $K -n flux-system get kustomization $KS -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null; }
ksmsg() { $K -n flux-system get kustomization $KS -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}: {.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null | cut -c1-160; }
operator() { $K -n external-secrets scale deploy external-secrets --replicas="$1" >/dev/null || fail "could not scale the operator to $1"; }
operator_gone() { [ -z "$($K -n external-secrets get pods -l app.kubernetes.io/name=external-secrets -o name 2>/dev/null)" ] && echo gone || echo running; }
request() { $K -n flux-system annotate kustomization $KS reconcile.fluxcd.io/requestedAt="$(date +%s%N)" --overwrite >/dev/null; }
fail() { echo "UNEXPECTED: $*"; exit 1; }
restore() {
  echo "-- restore"
  $K -n external-secrets scale deploy external-secrets --replicas=1 >/dev/null
  $K -n external-secrets rollout status deploy/external-secrets --timeout=180s >/dev/null
  $F reconcile kustomization $KS --timeout 3m >/dev/null 2>&1
  echo "restored: operator replicas $($K -n external-secrets get deploy external-secrets -o jsonpath='{.status.readyReplicas}'), $KS Ready=$(ks)"
}
trap restore EXIT
echo "flux health rows start=$(now)"
[ "$(ks)" = True ] || fail "$KS is not Ready before the rows: $(ksmsg)"

echo "== H1 an ExternalSecret the operator has never seen"
# Deleted while the operator runs: its cleanup finalizer holds a deletion until the operator is back,
# so with the operator already stopped the object would sit in Terminating instead.
$K -n $NS delete externalsecret ssm-app-worker --timeout=60s >/dev/null || fail "could not delete ssm-app-worker"
operator 0; T0=$(date -u +%s); r=$(waitfor 120 operator_gone gone) || fail "the operator did not stop: $r"
request; sleep 60
st=$(ks); echo "   60s after Flux re-applied it, with the operator stopped: Ready=$st ($(ksmsg))"
echo "   the ExternalSecret's status: '$($K -n $NS get externalsecret ssm-app-worker -o jsonpath='{.status}' 2>/dev/null)'"
[ "$st" != True ] || fail "the group went Ready on an ExternalSecret the operator never synced"
operator 1; T0=$(date -u +%s)
r=$(waitfor 240 ks True) || fail "the group did not turn Ready once the operator was back: $r"
echo "   operator back: group Ready $r"

echo "== H2 an ExternalSecret whose spec moved past its last sync"
g0=$($K -n $NS get externalsecret ssm-app -o jsonpath='{.metadata.generation}')
operator 0; T0=$(date -u +%s); r=$(waitfor 120 operator_gone gone) || fail "the operator did not stop: $r"
$K -n $NS patch externalsecret ssm-app --type merge -p '{"spec":{"refreshInterval":"59m"}}' >/dev/null || fail "could not change the spec"
request; sleep 60
g1=$($K -n $NS get externalsecret ssm-app -o jsonpath='{.metadata.generation}')
synced=$($K -n $NS get externalsecret ssm-app -o jsonpath='{.status.syncedResourceVersion}' | cut -d- -f1)
st=$(ks); echo "   generation $g0 -> $g1 (Flux re-applied the spec in Git), last synced generation $synced, Ready condition still $($K -n $NS get externalsecret ssm-app -o jsonpath='{.status.conditions[0].status}')"
echo "   60s later, with the operator stopped: group Ready=$st ($(ksmsg))"
[ "$st" != True ] || fail "the group went Ready on a spec the operator never synced"
operator 1; T0=$(date -u +%s)
r=$(waitfor 240 ks True) || fail "the group did not turn Ready once the operator was back: $r"
echo "   operator back: group Ready $r, synced generation $($K -n $NS get externalsecret ssm-app -o jsonpath='{.status.syncedResourceVersion}' | cut -d- -f1) of $($K -n $NS get externalsecret ssm-app -o jsonpath='{.metadata.generation}')"
echo "flux health rows end=$(now)"
