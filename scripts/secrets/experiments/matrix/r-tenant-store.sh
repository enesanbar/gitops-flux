#!/usr/bin/env bash
# The tenant store shape: one ClusterSecretStore on a delivered credential (components/aws-parameterstore)
# and the ssm-app reference that reads through it. Prints statuses, digests of values and timings only.
#   A  a key pinned to one parameter version holds while the token beside it rotates
#   B  a JSON credential rotates both fields in one sync
#   C  the store refuses a namespace it does not list; a listed namespace may read another's path
#   D  the delivered credential rotates underneath the store (a -> b, a revoked), then dies and recovers
#   E  two ExternalSecrets claiming one Secret, and the absence window when a key-class ExternalSecret goes
#   F  the delivered credential Secret disappears
# Mutates the lab: writes new parameter versions, toggles the stand-in's access keys (the lab user may),
# deletes the reference Secret once. The exit trap puts both keys back to Active, key a in the Secret,
# removes every probe and has Flux re-apply the reference. ROWS=ADE runs a subset (default all).
source "$(dirname "$0")/lib.sh"
ROWS="${ROWS:-ABCDEF}"; row() { case "$ROWS" in *"$1"*) return 0 ;; esac; return 1; }
H="$W/scripts/secrets/ssm.sh"; A="$W/scripts/secrets/aws-credentials.sh"; NS=ssm-app; OUT=secret-lab-ssm-outsider
R=/devops/dev-cluster/ssm-app

lab_aws() {
  ( unset AWS_PROFILE AWS_DEFAULT_PROFILE
    AWS_ACCESS_KEY_ID="$(cat "$SECRET_STATE_DIR/aws/access_key_id")"
    AWS_SECRET_ACCESS_KEY="$(cat "$SECRET_STATE_DIR/aws/secret_access_key")"
    AWS_REGION="$(jq -r .region "$SECRET_STATE_DIR/aws/config.json")"
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION AWS_PAGER=""
    aws "$@" )
}
key_status() { lab_aws iam update-access-key --user-name eso-lab-tenant --access-key-id "$(cat "$SECRET_STATE_DIR/aws/tenant/$1/access_key_id")" --status "$2"; }
# a digest that cannot be mistaken for a value: ERR when the read fails, ABSENT when the key is missing
kd() { local v; v=$($K -n "$1" get secret "$2" -o go-template="{{with index .data \"$3\"}}{{.}}{{end}}" 2>/dev/null) || { echo ERR; return; }
  [ -n "$v" ] || { echo ABSENT; return; }; printf '%s' "$v" | shasum -a 256 | cut -c1-12; }
scrub() { sed -E 's/arn:aws:[^ ]*/<arn>/g; s/[0-9]{12}/<account>/g; s/(RequestID|request id)[: ]+[-0-9a-f]+/\1 <id>/Ig'; }
cause() { $K -n "$1" get events --field-selector "involvedObject.name=$2" --sort-by=.lastTimestamp -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null |
  tail -1 | scrub | cut -c1-220; }
msg() { esmsg "$@" | scrub; }
css() { $K get clustersecretstore aws-parameterstore -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null; }
fail() { echo "UNEXPECTED: $*"; exit 1; }
sync_all() { local e; for e in ssm-app ssm-app-database ssm-app-worker ssm-app-tls; do sync $NS $e; done; }
# An access key toggled in IAM takes effect after a propagation delay (about three minutes to bite
# on deactivation, measured here), so a row that follows a toggle waits for this, never reads once.
synced_after_sync() { sync_all; sleep 5; all_synced; }
all_synced() { local e s=ok; for e in ssm-app ssm-app-database ssm-app-worker ssm-app-tls; do [ "$(es $NS $e)" = SecretSynced ] || s=no; done; echo $s; }

restore() {
  echo "-- restore"
  key_status a Active; key_status b Active
  "$A" tenant a >/dev/null
  $K delete namespace "$OUT" --ignore-not-found --wait=false >/dev/null
  $K -n $NS delete externalsecret probe-cross-namespace ssm-app-claimant --ignore-not-found >/dev/null
  $F reconcile kustomization ssm-app-secrets --timeout 3m >/dev/null 2>&1
  echo "restored: keys a,b Active; external-secrets/aws-credentials holds key a; probes gone; reference re-applied"
}
trap restore EXIT
echo "tenant store rows start=$(now) store=$(css)"
[ "$(all_synced)" = ok ] || fail "the reference is not synced before the rows"

if row A; then
echo "== A. pin versus a rotating neighbour"
k0=$(kd $NS ssm-app ENCRYPTION_KEY); t0=$(kd $NS ssm-app SERVICE_TOKEN)
openssl rand -base64 32 | "$H" put $R/encryption_key --overwrite --new-key-version \
  --description "Example application encryption key. Generated with openssl rand. Rotates only through the application's two-key re-wrap; consumers pin a version." >/dev/null
openssl rand -hex 32 | "$H" put $R/service_token --overwrite \
  --description "Example service token. Generated with openssl rand. Rotate by writing a new version, then roll the consumer." >/dev/null
T0=$(date -u +%s); sync $NS ssm-app
r=$(waitfor 120 "[ \"\$(kd $NS ssm-app SERVICE_TOKEN)\" != '$t0' ] && echo changed || echo same" changed) || fail "token did not follow: $r"
echo "token followed: $r"
k1=$(kd $NS ssm-app ENCRYPTION_KEY)
echo "key digest before=$k0 after=$k1 (pinned to version 1 while version 2 exists) status=$(es $NS ssm-app)"
[ "$k0" = "$k1" ] || fail "the pinned key changed"
fi
if row B; then
echo "== B. a JSON credential rotates as one"
u0=$(kd $NS ssm-app-database username); p0=$(kd $NS ssm-app-database password)
{ openssl rand -hex 4; openssl rand -hex 16; } | jq -Rsc 'split("\n") | {username: ("ssm_app_" + .[0]), password: .[1]}' |
  "$H" put $R/database --overwrite \
  --description "Example database account as one JSON object; username and password are replaced together." >/dev/null
T0=$(date -u +%s); sync $NS ssm-app-database
r=$(waitfor 120 "[ \"\$(kd $NS ssm-app-database password)\" != '$p0' ] && echo changed || echo same" changed) || fail "password did not follow: $r"
echo "password followed: $r"
u1=$(kd $NS ssm-app-database username)
echo "username digest before=$u0 after=$u1 (must differ: both fields arrive from the one read)"
[ "$u0" != "$u1" ] || fail "username did not follow with the password"
fi
if row C; then
echo "== C. who may use the store"
$K create namespace $OUT --dry-run=client -o yaml | $K apply -f - >/dev/null
cat <<EOF | $K apply -f - >/dev/null
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: {name: outsider, namespace: $OUT}
spec:
  refreshInterval: 1h
  secretStoreRef: {name: aws-parameterstore, kind: ClusterSecretStore}
  target: {name: outsider, creationPolicy: Owner}
  data: [{secretKey: TOKEN, remoteRef: {key: $R/service_token}}]
EOF
T0=$(date -u +%s)
echo "unlisted namespace: $(waitfor 60 "es $OUT outsider" SecretSyncedError)"
echo "   condition: $(msg $OUT outsider)"; echo "   event: $(cause $OUT outsider)"; echo "   secret: $(kd $OUT outsider TOKEN)"
openssl rand -hex 8 | "$H" put /devops/dev-cluster/$OUT/probe --description "Probe owned by another namespace." >/dev/null
cat <<EOF | $K apply -f - >/dev/null
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: {name: probe-cross-namespace, namespace: $NS}
spec:
  refreshInterval: 1h
  secretStoreRef: {name: aws-parameterstore, kind: ClusterSecretStore}
  target: {name: probe-cross-namespace, creationPolicy: Owner}
  data: [{secretKey: PROBE, remoteRef: {key: /devops/dev-cluster/$OUT/probe}}]
EOF
T0=$(date -u +%s)
echo "listed namespace reading another namespace's path: $(waitfor 60 "es $NS probe-cross-namespace" SecretSynced) (nothing but review and CI stops this)"
$K -n $NS delete externalsecret probe-cross-namespace >/dev/null
lab_aws ssm delete-parameter --name /devops/dev-cluster/$OUT/probe >/dev/null
$K delete namespace $OUT --wait=false >/dev/null
fi
if row D; then
echo "== D. the delivered credential rotates underneath the store"
"$A" tenant b >/dev/null; T0=$(date -u +%s); sync_all
r=$(waitfor 90 all_synced ok) || fail "the reference did not sync on key b: $r"
echo "after the swap to key b: $r store=$(css)"
key_status a Inactive; T0=$(date -u +%s)
ok=0; for i in $(seq 1 8); do sync_all; sleep 15; [ "$(all_synced)" = ok ] && ok=$((ok+1)); done
echo "key a revoked: $ok of 8 forced syncs over 120s stayed synced on key b @$(el)"
[ "$ok" = 8 ] || fail "the store did not follow the credential Secret"
d0=$(kd $NS ssm-app SERVICE_TOKEN)
key_status b Inactive; T0=$(date -u +%s)
for i in $(seq 1 24); do sync $NS ssm-app; sleep 10; [ "$(es $NS ssm-app)" = SecretSyncedError ] && break; done
echo "key b revoked (the one in use): ExternalSecret $(es $NS ssm-app) @$(el) store=$(css)"
echo "   condition: $(msg $NS ssm-app)"; echo "   event: $(cause $NS ssm-app)"
echo "   secret kept: $([ "$(kd $NS ssm-app SERVICE_TOKEN)" = "$d0" ] && echo yes || echo NO)"
key_status b Active; T0=$(date -u +%s)
for i in $(seq 1 24); do sync $NS ssm-app; sleep 10; [ "$(es $NS ssm-app)" = SecretSynced ] && break; done
echo "key b reactivated: ExternalSecret $(es $NS ssm-app) @$(el) (includes IAM propagation)"
key_status a Active; "$A" tenant a >/dev/null; T0=$(date -u +%s)
r=$(waitfor 300 synced_after_sync ok) || fail "key a did not come back: $r"
echo "key a active again and in the Secret: $r"
fi
if row E; then
echo "== E. who owns the Secret"
T0=$(date -u +%s); r=$(waitfor 300 synced_after_sync ok) || fail "the reference is not syncing before row E: $r"
$K -n $NS get externalsecret ssm-app -o json | jq '{apiVersion, kind, metadata: {name: "ssm-app-claimant", namespace: .metadata.namespace}, spec}' | $K apply -f - >/dev/null
T0=$(date -u +%s)
echo "a second ExternalSecret for the same Secret: $(waitfor 60 "es $NS ssm-app-claimant" SecretOwnedByOther)"
echo "   condition: $(msg $NS ssm-app-claimant)"; echo "   event: $(cause $NS ssm-app-claimant)"
sync $NS ssm-app; sleep 5; echo "   first, after its own sync: $(es $NS ssm-app)"
$K -n $NS delete externalsecret ssm-app-claimant >/dev/null
k2=$(kd $NS ssm-app ENCRYPTION_KEY); T0=$(date -u +%s)
$K -n $NS delete externalsecret ssm-app >/dev/null
echo "key-class ExternalSecret deleted: its Secret $(waitfor 60 "kd $NS ssm-app ENCRYPTION_KEY" ERR)"
$F reconcile kustomization ssm-app-secrets --timeout 3m >/dev/null 2>&1
r=$(waitfor 120 "es $NS ssm-app" SecretSynced) || fail "Flux did not bring the ExternalSecret back: $r"
echo "re-applied by Flux: $r; key digest $([ "$(kd $NS ssm-app ENCRYPTION_KEY)" = "$k2" ] && echo "identical to before" || echo CHANGED)"
fi
if row F; then
echo "== F. the delivered credential Secret disappears"
"$A" tenant-remove >/dev/null; T0=$(date -u +%s)
$K annotate clustersecretstore aws-parameterstore force-validate="$(date +%s%N)" --overwrite >/dev/null
echo "store without its credential: $(waitfor 120 css InvalidProviderConfig)"
sync $NS ssm-app-worker; sleep 10
echo "   ExternalSecret $(es $NS ssm-app-worker): $(msg $NS ssm-app-worker)"
echo "   secret kept: $([ "$(kd $NS ssm-app-worker BROKER_PASSWORD)" != ABSENT ] && echo yes || echo NO)"
"$A" tenant a >/dev/null; T0=$(date -u +%s)
$K annotate clustersecretstore aws-parameterstore force-validate="$(date +%s%N)" --overwrite >/dev/null
echo "credential back: store $(waitfor 120 css Valid)"
sync $NS ssm-app-worker
echo "   ExternalSecret $(waitfor 60 "es $NS ssm-app-worker" SecretSynced)"
fi
echo "tenant store rows end=$(now)"
