#!/usr/bin/env bash
# Does a generator's minted lifetime and its ExternalSecret's refresh interval relate? (They do not.)
# Sets the STS minimum lifetime against a refresh far longer than it, then watches the consuming store.
source "$(dirname "$0")/lib.sh"; NS=secret-lab-aws
es2() { $K -n $NS get externalsecret "$1" -o jsonpath='{.status.conditions[0].reason}'; }
echo "STS expiry start=$(now)"; $F suspend kustomization secret-lab-aws >/dev/null
$K -n $NS patch vaultdynamicsecret aws-sts --type merge -p '{"spec":{"parameters":{"ttl":900}}}' >/dev/null
$K -n $NS patch externalsecret aws-sts-credentials --type merge -p '{"spec":{"refreshInterval":"90m"}}' >/dev/null
$K -n $NS annotate externalsecret aws-sts-credentials force-sync="$(date +%s%N)" --overwrite >/dev/null; sleep 15
minted=$($K -n $NS get externalsecret aws-sts-credentials -o jsonpath='{.status.refreshTime}')
echo "minted at $minted with a 900s lifetime under a 90m refresh; the consuming store must fail ~15 min later"
T0=$(date -u +%s)
for i in $(seq 1 80); do
  $K -n $NS annotate externalsecret trellis-secrets-vault-minted force-sync="$(date +%s%N)" --overwrite >/dev/null; sleep 15
  st=$(es2 trellis-secrets-vault-minted)
  if [ "$st" != "SecretSynced" ]; then
    echo "$(el) consuming store FAILED while the credentials ExternalSecret still reports $(es2 aws-sts-credentials) and the SecretStore reports $($K -n $NS get secretstore aws-vault-minted -o jsonpath='{.status.conditions[0].reason}')"
    $K -n $NS get events --field-selector involvedObject.name=trellis-secrets-vault-minted -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' | grep -oE 'ExpiredToken[A-Za-z]*|expired' | tail -1 | sed 's/^/   cause: /'
    break
  fi
done
echo "-- restore: lifetime 3600, refresh 30m, fresh mint"
$K -n $NS patch vaultdynamicsecret aws-sts --type merge -p '{"spec":{"parameters":{"ttl":3600}}}' >/dev/null
$K -n $NS patch externalsecret aws-sts-credentials --type merge -p '{"spec":{"refreshInterval":"30m"}}' >/dev/null
$K -n $NS annotate externalsecret aws-sts-credentials force-sync="$(date +%s%N)" --overwrite >/dev/null; sleep 20
T0=$(date -u +%s); $K -n $NS annotate externalsecret trellis-secrets-vault-minted force-sync="$(date +%s%N)" --overwrite >/dev/null
echo "[wait began $(el)] consuming store recovered: $(waitfor 180 "es2 trellis-secrets-vault-minted" SecretSynced)"
$F resume kustomization secret-lab-aws --timeout 3m >/dev/null 2>&1
echo "STS expiry end=$(now)"
