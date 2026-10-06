#!/usr/bin/env bash
# The tenant store shape: one ClusterSecretStore on a delivered credential (components/aws-parameterstore)
# and the ssm-app reference that reads through it. Prints statuses, digests of values and timings only.
#   A  a key pinned to one parameter version holds while the token beside it rotates
#   B  a JSON credential rotates both fields in one sync
#   C  the store refuses a namespace it does not list; a listed namespace may read another's path
#   D  the delivered credential replaced underneath the store: a key AWS does not know, then a real
#      rotation, then the key in use revoked (IAM propagation) and restored
#   E  two ExternalSecrets claiming one Secret, and the absence window when a key-class ExternalSecret goes
#   F  the delivered credential Secret disappears, noticed at the next validation and forced
# A sync counts only when the ExternalSecret's refreshTime is later than the request for it: a reason
# left over from an earlier sync proves nothing. Every mutation's result is checked, and the first
# unexpected answer stops the run. Mutates the lab: new parameter versions, the stand-in's access keys
# toggled (the lab user may), the reference Secret deleted once, the operator's credential Secret
# replaced. The exit trap puts both keys back to Active, key a in the Secret, removes every probe, has
# Flux re-apply the reference, and prints what it actually found. ROWS=ADE runs a subset.
source "$(dirname "$0")/lib.sh"
ROWS="${ROWS:-ABCDEF}"; row() { case "$ROWS" in *"$1"*) return 0 ;; esac; return 1; }
H="$W/scripts/secrets/ssm.sh"; A="$W/scripts/secrets/aws-credentials.sh"; NS=ssm-app; OUT=secret-lab-ssm-outsider
R=/devops/dev-cluster/ssm-app; PROBE=/devops/dev-cluster/$OUT/probe
REFERENCE=(ssm-app ssm-app-database ssm-app-worker ssm-app-tls)

fail() { echo "UNEXPECTED: $*"; exit 1; }
lab_aws() {
  ( unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_SESSION_TOKEN
    AWS_ACCESS_KEY_ID="$(cat "$SECRET_STATE_DIR/aws/access_key_id")"
    AWS_SECRET_ACCESS_KEY="$(cat "$SECRET_STATE_DIR/aws/secret_access_key")"
    AWS_REGION="$(jq -r .region "$SECRET_STATE_DIR/aws/config.json")"
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION AWS_PAGER=""
    aws "$@" )
}
key_id() { cat "$SECRET_STATE_DIR/aws/tenant/$1/access_key_id"; }
set_key() { lab_aws iam update-access-key --user-name eso-lab-tenant --access-key-id "$(key_id "$1")" --status "$2"; }
key_status() { set_key "$1" "$2" || fail "could not set key $1 $2"; }
key_statuses() { lab_aws iam list-access-keys --user-name eso-lab-tenant --output json | jq -r '[.AccessKeyMetadata[].Status] | sort | join(",")'; }
latest_version() { lab_aws ssm describe-parameters --parameter-filters "Key=Name,Option=Equals,Values=$1" --output json | jq -r '.Parameters[0].Version'; }
# A credential that is not a key AWS knows, in the shape a platform delivers.
deliver_unknown() {
  $K -n external-secrets create secret generic aws-credentials --from-literal=aws_access_key_id=AKIAIOSFODNN7INVALID \
    --from-literal=aws_secret_access_key=not-a-real-secret-key --dry-run=client -o yaml |
    $K apply --server-side --field-manager=tenant-bootstrap --force-conflicts -f - >/dev/null || fail "could not deliver the unknown key"
}
deliver() { "$A" tenant "$1" >/dev/null || fail "could not deliver tenant key $1"; }
# a digest that cannot be mistaken for a value: ERR when the read fails, ABSENT when the key is missing
kd() { local v; v=$($K -n "$1" get secret "$2" -o go-template="{{with index .data \"$3\"}}{{.}}{{end}}" 2>/dev/null) || { echo ERR; return; }
  [ -n "$v" ] || { echo ABSENT; return; }; printf '%s' "$v" | shasum -a 256 | cut -c1-12; }
scrub() { sed -E 's/arn:aws:[^ ]*/<arn>/g; s/[0-9]{12}/<account>/g; s/(RequestID|request id)[: ]+[-0-9a-f]+/\1 <id>/Ig'; }
cause() { $K -n "$1" get events --field-selector "involvedObject.name=$2" --sort-by=.lastTimestamp \
  -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null | tail -1 | scrub | cut -c1-400; }
msg() { $K -n "$1" get externalsecret "$2" -o jsonpath='{.status.conditions[0].message}' 2>/dev/null | scrub; }
css() { $K get clustersecretstore aws-parameterstore -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null; }
refreshed() { $K -n "$1" get externalsecret "$2" -o jsonpath='{.status.refreshTime}' 2>/dev/null; }
# Force a sync and report how it ended: synced once its refreshTime moves past the one read before the
# request (no host clock involved, so a drifting node clock cannot fake it), failed once the condition
# reads SecretSyncedError, pending otherwise. Expecting a success (a fourth argument of synced), the
# SecretSyncedError the sync before left behind is not this sync's result, so it keeps polling.
sync_outcome() {
  local ns=$1 es=$2 polls=${3:-12} want=${4:-} before i r
  before=$(refreshed "$ns" "$es"); sync "$ns" "$es"
  for i in $(seq 1 "$polls"); do
    sleep 5; r=$(refreshed "$ns" "$es")
    [ -n "$r" ] && [ "$r" != "$before" ] && [ "$(es "$ns" "$es")" = SecretSynced ] && { echo synced; return; }
    [ "$want" != synced ] && [ "$(es "$ns" "$es")" = SecretSyncedError ] && { echo failed; return; }
  done
  if [ "$(es "$ns" "$es")" = SecretSyncedError ]; then echo failed; else echo pending; fi
}
revalidate() { $K annotate clustersecretstore aws-parameterstore force-validate="$(date +%s%N)" --overwrite >/dev/null; }
out_of_the_way() { $K delete namespace "$OUT" --ignore-not-found --wait=false >/dev/null
  $K -n $NS delete externalsecret probe-cross-namespace ssm-app-claimant --ignore-not-found >/dev/null
  lab_aws ssm delete-parameter --name "$PROBE" >/dev/null 2>&1 || true; }

# Runs as the exit trap, so a step that fails is reported and the rest still run: stopping at the first
# would leave the store on whatever credential the interrupted row put there.
restore() {
  local incomplete=""
  echo "-- restore"
  set_key a Active || incomplete+=" key-a"
  set_key b Active || incomplete+=" key-b"
  "$A" tenant a >/dev/null || incomplete+=" delivery"
  revalidate || incomplete+=" revalidate"
  out_of_the_way
  $F reconcile kustomization ssm-app-secrets --timeout 3m >/dev/null 2>&1 || incomplete+=" flux"
  echo "restored: stand-in keys $(key_statuses); store $(css); reference ExternalSecrets $(for e in "${REFERENCE[@]}"; do printf '%s ' "$(es $NS "$e")"; done)"
  [ -z "$incomplete" ] || { echo "RESTORE INCOMPLETE:$incomplete"; exit 1; }
}
trap restore EXIT
echo "tenant store rows start=$(now) store=$(css) rows=$ROWS"
for e in "${REFERENCE[@]}"; do [ "$(sync_outcome $NS "$e")" = synced ] || fail "$e does not sync before the rows"; done

if row A; then
echo "== A. pin versus a rotating neighbour"
v0=$(latest_version $R/encryption_key); k0=$(kd $NS ssm-app ENCRYPTION_KEY); t0=$(kd $NS ssm-app SERVICE_TOKEN)
openssl rand -base64 32 | "$H" put $R/encryption_key --overwrite --new-key-version \
  --description "Example application encryption key. Generated with openssl rand. Rotates only through the application's two-key re-wrap; consumers pin a version." >/dev/null || fail "key write"
openssl rand -hex 32 | "$H" put $R/service_token --overwrite \
  --description "Example service token. Generated with openssl rand. Rotate by writing a new version, then roll the consumer." >/dev/null || fail "token write"
v1=$(latest_version $R/encryption_key); [ "$v1" -gt "$v0" ] || fail "the key's version did not move ($v0 -> $v1)"
T0=$(date -u +%s); o=$(sync_outcome $NS ssm-app); [ "$o" = synced ] || fail "ssm-app did not sync: $o"
k1=$(kd $NS ssm-app ENCRYPTION_KEY); t1=$(kd $NS ssm-app SERVICE_TOKEN)
echo "key latest version $v0 -> $v1, pinned 1: digest $k0 -> $k1; token digest $t0 -> $t1; synced within $(el)"
[ "$k0" = "$k1" ] && [ "$k0" != ERR ] || fail "the pinned key changed"
[ "$t0" != "$t1" ] || fail "the token did not follow"
fi

if row B; then
echo "== B. a JSON credential rotates as one"
u0=$(kd $NS ssm-app-database username); p0=$(kd $NS ssm-app-database password)
{ openssl rand -hex 4; openssl rand -hex 16; } | jq -Rsc 'split("\n") | {username: ("ssm_app_" + .[0]), password: .[1]}' |
  "$H" put $R/database --overwrite --description "Example database account as one JSON object; username and password are replaced together." >/dev/null || fail "JSON write"
T0=$(date -u +%s); o=$(sync_outcome $NS ssm-app-database); [ "$o" = synced ] || fail "ssm-app-database did not sync: $o"
u1=$(kd $NS ssm-app-database username); p1=$(kd $NS ssm-app-database password)
echo "one write, one sync within $(el): username digest $u0 -> $u1, password digest $p0 -> $p1"
[ "$u0" != "$u1" ] && [ "$p0" != "$p1" ] || fail "the two fields did not change together"
fi

if row C; then
echo "== C. who may use the store"
$K create namespace $OUT --dry-run=client -o yaml | $K apply -f - >/dev/null || fail "outsider namespace"
cat <<EOF | $K apply -f - >/dev/null || fail "outsider ExternalSecret"
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: {name: outsider, namespace: $OUT}
spec:
  refreshInterval: 1h
  secretStoreRef: {name: aws-parameterstore, kind: ClusterSecretStore}
  target: {name: outsider, creationPolicy: Owner}
  data: [{secretKey: TOKEN, remoteRef: {key: $R/service_token}}]
EOF
T0=$(date -u +%s); r=$(waitfor 60 "es $OUT outsider" SecretSyncedError) || fail "the unlisted namespace was not refused: $r"
why=$(cause $OUT outsider); echo "unlisted namespace refused $r; condition: $(msg $OUT outsider); event: $why"
[[ $why == *"denied by spec.condition"* ]] || fail "refused for another reason"
[ "$(kd $OUT outsider TOKEN)" = ERR ] || fail "a Secret was created in the unlisted namespace"
openssl rand -hex 8 | "$H" put $PROBE --description "Probe owned by another namespace." >/dev/null || fail "probe write"
cat <<EOF | $K apply -f - >/dev/null || fail "cross-namespace ExternalSecret"
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: {name: probe-cross-namespace, namespace: $NS}
spec:
  refreshInterval: 1h
  secretStoreRef: {name: aws-parameterstore, kind: ClusterSecretStore}
  target: {name: probe-cross-namespace, creationPolicy: Owner}
  data: [{secretKey: PROBE, remoteRef: {key: $PROBE}}]
EOF
T0=$(date -u +%s); r=$(waitfor 60 "es $NS probe-cross-namespace" SecretSynced) || fail "the cross-namespace read did not sync: $r"
echo "a listed namespace read another namespace's path: synced $r (nothing but review, CI and RBAC stops this)"
out_of_the_way
fi

if row D; then
echo "== D. the delivered credential replaced underneath the store"
deliver_unknown; T0=$(date -u +%s); o=$(sync_outcome $NS ssm-app-worker)
echo "D1 a key AWS does not know: next sync $o within $(el); store $(css); event: $(cause $NS ssm-app-worker)"
[ "$o" = failed ] || fail "the store did not use the replaced credential"
deliver a; T0=$(date -u +%s); o=$(sync_outcome $NS ssm-app-worker 12 synced)
echo "D2 key a back: next sync $o within $(el)"; [ "$o" = synced ] || fail "key a did not work again"
deliver b; T0=$(date -u +%s); o=$(sync_outcome $NS ssm-app-worker 12 synced)
echo "D3 rotated to key b, both valid: next sync $o within $(el)"; [ "$o" = synced ] || fail "key b did not work"
d0=$(kd $NS ssm-app-worker BROKER_PASSWORD)
key_status b Inactive; T0=$(date -u +%s)
for i in $(seq 1 36); do o=$(sync_outcome $NS ssm-app-worker 2); [ "$o" = failed ] && break; sleep 5; done
kept=$([ "$(kd $NS ssm-app-worker BROKER_PASSWORD)" = "$d0" ] && echo yes || echo NO)
echo "D4 key b (in use) deactivated: first failed sync $(el) later; store $(css); Secret kept: $kept"
echo "   condition: $(msg $NS ssm-app-worker)"; echo "   event: $(cause $NS ssm-app-worker)"
[ "$o" = failed ] || fail "the deactivation never took effect within the window"
[ "$kept" = yes ] || fail "the Secret changed while syncs failed"
key_status b Active; T0=$(date -u +%s)
for i in $(seq 1 36); do o=$(sync_outcome $NS ssm-app-worker 2 synced); [ "$o" = synced ] && break; sleep 5; done
echo "D5 key b reactivated: first successful sync $(el) later"; [ "$o" = synced ] || fail "key b did not come back"
deliver a
fi

if row E; then
echo "== E. who owns the Secret"
$K -n $NS get externalsecret ssm-app -o json | jq '{apiVersion, kind, metadata: {name: "ssm-app-claimant", namespace: .metadata.namespace}, spec}' |
  $K apply -f - >/dev/null || fail "claimant"
T0=$(date -u +%s); r=$(waitfor 60 "es $NS ssm-app-claimant" SecretOwnedByOther) || fail "the claimant was not refused as owned by another: $r"
echo "a second ExternalSecret for the same Secret: $r; condition: $(msg $NS ssm-app-claimant); event: $(cause $NS ssm-app-claimant)"
o=$(sync_outcome $NS ssm-app 12 synced); echo "   the first, synced again: $o"; [ "$o" = synced ] || fail "the first stopped serving"
$K -n $NS delete externalsecret ssm-app-claimant >/dev/null || fail "claimant cleanup"
k2=$(kd $NS ssm-app ENCRYPTION_KEY); T0=$(date -u +%s)
$K -n $NS delete externalsecret ssm-app >/dev/null || fail "delete the key-class ExternalSecret"
r=$(waitfor 60 "kd $NS ssm-app ENCRYPTION_KEY" ERR) || fail "its Secret was not garbage-collected: $r"
echo "key-class ExternalSecret deleted: its Secret gone $r"
$F reconcile kustomization ssm-app-secrets --timeout 3m >/dev/null 2>&1 || fail "Flux did not re-apply the reference"
echo "re-applied by Flux (its health check waits for the synced generation): Secret back within $(el), key digest $([ "$(kd $NS ssm-app ENCRYPTION_KEY)" = "$k2" ] && echo "identical to before" || echo CHANGED)"
[ "$(kd $NS ssm-app ENCRYPTION_KEY)" = "$k2" ] || fail "the key came back different"
fi

if row F; then
echo "== F. the delivered credential Secret disappears"
"$A" tenant-remove >/dev/null || fail "remove the credential"
T0=$(date -u +%s); o=$(sync_outcome $NS ssm-app-worker)
echo "F1 before the store notices: store $(css); next sync $o; condition: $(msg $NS ssm-app-worker); event: $(cause $NS ssm-app-worker)"
[ "$o" = failed ] || fail "a sync without the credential did not fail"
revalidate; T0=$(date -u +%s); r=$(waitfor 120 css InvalidProviderConfig) || fail "the store did not notice on a forced validation: $r"
# F1 already left the ExternalSecret failed, so the outcome alone cannot show that this sync failed on
# the store; the event naming the store does.
o=$(sync_outcome $NS ssm-app-worker)
e2=$(waitfor 60 "cause $NS ssm-app-worker | grep -c 'is not ready'" 1) || fail "no sync failed on the store after the validation: $e2"
echo "F2 after a forced validation: store InvalidProviderConfig $r; next sync $o, failing on the store ${e2#1 }; event: $(cause $NS ssm-app-worker)"
kept=$([ "$(kd $NS ssm-app-worker BROKER_PASSWORD)" != ABSENT ] && [ "$(kd $NS ssm-app-worker BROKER_PASSWORD)" != ERR ] && echo yes || echo NO)
echo "   Secret kept: $kept"; [ "$kept" = yes ] || fail "the Secret went while the store was not ready"
deliver a; revalidate; T0=$(date -u +%s); r=$(waitfor 120 css Valid) || fail "the store did not recover: $r"
o=$(sync_outcome $NS ssm-app-worker 12 synced); echo "F3 credential back, validation forced: store Valid $r; next sync $o"
[ "$o" = synced ] || fail "the sync did not recover"
fi
echo "tenant store rows end=$(now)"
