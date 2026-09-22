#!/usr/bin/env bash
# The rows the Vault half measured that the AWS half had not: generated Secret deleted by hand,
# malformed ExternalSecret, ESO restart during a rotation, consumer restart, certificate rotation,
# and the Retain/Delete contrast on a deleted parameter. Values move through files, never arguments.
source "$(dirname "$0")/lib.sh"; NS=secret-lab-aws
export AWS_DEFAULT_REGION=$(jq -r .region "$SECRET_STATE_DIR/aws/config.json")
export AWS_ACCESS_KEY_ID="$(cat "$SECRET_STATE_DIR/aws/access_key_id")" AWS_SECRET_ACCESS_KEY="$(cat "$SECRET_STATE_DIR/aws/secret_access_key")"
unset AWS_PROFILE AWS_SESSION_TOKEN
es2() { $K -n $NS get externalsecret "$1" -o jsonpath='{.status.conditions[0].reason}'; }
k2() { $K -n $NS get secret "$1" -o go-template="{{with index .data \"$2\"}}{{len .}}{{else}}absent{{end}}" 2>/dev/null || echo no-secret; }
sync2() { $K -n $NS annotate externalsecret "$1" force-sync="$(date +%s%N)" --overwrite >/dev/null; }
echo "AWS rows start=$(now)"; $F suspend kustomization secret-lab-aws >/dev/null

echo "== generated Secret deleted by hand =="
T0=$(date -u +%s); $K -n $NS delete secret trellis-secrets-static >/dev/null
echo "[wait began $(el)] ESO recreated it: $(waitfor 120 "k2 trellis-secrets-static TRELLIS_KEK" 60)"

echo "== malformed ExternalSecret (three shapes) =="
printf 'apiVersion: external-secrets.io/v1\nkind: ExternalSecret\nmetadata: {name: bad-schema-aws, namespace: secret-lab-aws}\nspec:\n  refreshPolicy: Sometimes\n  secretStoreRef: {name: aws-static, kind: SecretStore}\n  target: {name: bad-schema-aws}\n  data:\n  - secretKey: x\n    remoteRef: {key: /lab-cluster00/trellis/llm}\n' | $K apply -f - 2>&1 | cut -c1-200 | sed 's/^/   (a) /'
printf 'apiVersion: external-secrets.io/v1\nkind: ExternalSecret\nmetadata: {name: bad-template-aws, namespace: secret-lab-aws}\nspec:\n  refreshPolicy: Periodic\n  refreshInterval: 1m\n  secretStoreRef: {name: aws-static, kind: SecretStore}\n  target:\n    name: bad-template-aws\n    template:\n      engineVersion: v2\n      data: {out: "{{ .missing }}"}\n  data:\n  - secretKey: x\n    remoteRef: {key: /lab-cluster00/trellis/llm}\n' | $K apply -f - >/dev/null 2>&1; sleep 10
echo "   (b) bad template: status=$(es2 bad-template-aws) secret=$(k2 bad-template-aws out)"
printf 'apiVersion: external-secrets.io/v1\nkind: ExternalSecret\nmetadata: {name: bad-name-aws, namespace: secret-lab-aws}\nspec:\n  refreshPolicy: Periodic\n  refreshInterval: 1m\n  secretStoreRef: {name: aws-static, kind: SecretStore}\n  target: {name: bad-name-aws}\n  data:\n  - secretKey: x\n    remoteRef: {key: /lab-cluster00/trellis/nope}\n' | $K apply -f - >/dev/null 2>&1; sleep 10
echo "   (c) missing parameter: status=$(es2 bad-name-aws) secret=$(k2 bad-name-aws x)"
$K -n $NS delete externalsecret bad-template-aws bad-name-aws --ignore-not-found >/dev/null

echo "== ESO controller restarted right after an SSM write =="
before=$(k2 llm-key-only TRELLIS_LLM_API_KEY); T0=$(date -u +%s)
aws ssm put-parameter --name /lab-cluster00/trellis/llm --type String --value "rot-$(openssl rand -hex 30)" --overwrite --query Version --output text | sed 's/^/   new version /'
$K -n external-secrets rollout restart deploy/external-secrets >/dev/null
for i in $(seq 1 40); do l=$(k2 llm-key-only TRELLIS_LLM_API_KEY); [ "$l" != "$before" ] && { echo "   $(el) Secret updated across the controller restart (b64len $before -> $l)"; break; }; sleep 5; done

echo "== consumer restart: does a new pod get the current Secret? =="
T0=$(date -u +%s); $K -n $NS rollout restart deploy/consumer >/dev/null; $K -n $NS rollout status deploy/consumer --timeout=180s >/dev/null 2>&1
echo "   $(el) consumer restarted; composed Secret key lengths: KEK=$(k2 trellis-secrets-static TRELLIS_KEK) LLM=$(k2 trellis-secrets-static TRELLIS_LLM_API_KEY)"

echo "== certificate rotation from SSM =="
tmp=$(mktemp -d "$SECRET_STATE_DIR/.ssm-cert.XXXXXX")
mkcert -cert-file "$tmp/crt.pem" -key-file "$tmp/key.pem" rotated.kindcluster.dev >/dev/null 2>&1; chmod 600 "$tmp"/*.pem
newlen=$(base64 < "$tmp/crt.pem" | tr -d '\n' | wc -c | tr -d ' ')
jq -n --arg v "$(cat "$tmp/crt.pem")" '{Name:"/lab-cluster00/tls/wildcard_certificate",Type:"SecureString",Value:$v,Overwrite:true}' > "$tmp/put.json"; chmod 600 "$tmp/put.json"
T0=$(date -u +%s); aws ssm put-parameter --cli-input-json "file://$tmp/put.json" --query Version --output text | sed 's/^/   certificate parameter version /'
old=$(k2 wildcard-from-ssm tls.crt); for i in $(seq 1 24); do l=$(k2 wildcard-from-ssm tls.crt); [ "$l" != "$old" ] && { echo "   $(el) typed TLS Secret followed the SSM rotation (b64len $old -> $l, type $($K -n $NS get secret wildcard-from-ssm -o jsonpath='{.type}'))"; break; }; sleep 5; done
rm -rf "$tmp"

echo "== deleted parameter: Retain vs Delete on two consumers of the same parameter =="
$K -n $NS patch externalsecret llm-key-only --type merge -p '{"spec":{"target":{"deletionPolicy":"Delete"}}}' >/dev/null
aws ssm delete-parameter --name /lab-cluster00/trellis/llm >/dev/null; T0=$(date -u +%s); sync2 trellis-secrets-static; sync2 llm-key-only; sleep 25
echo "   $(el) composed (Retain): $(es2 trellis-secrets-static) secret LLM=$(k2 trellis-secrets-static TRELLIS_LLM_API_KEY)"
echo "   $(el) single (Delete):   $(es2 llm-key-only) secret=$(k2 llm-key-only TRELLIS_LLM_API_KEY)"
echo "-- restore the parameter from the Vault entry and the policy"
"$V" login >/dev/null; tmp=$(mktemp -d "$SECRET_STATE_DIR/.ssm-restore.XXXXXX")
"$V" cli kv get -mount=secret-lab -format=json trellis/llm > "$tmp/llm.json"; chmod 600 "$tmp/llm.json"
jq -n --arg v "$(jq -r .data.data.TRELLIS_LLM_API_KEY "$tmp/llm.json")" '{Name:"/lab-cluster00/trellis/llm",Type:"String",Value:$v,Overwrite:true}' > "$tmp/put.json"; chmod 600 "$tmp/put.json"
aws ssm put-parameter --cli-input-json "file://$tmp/put.json" --query Version --output text | sed 's/^/   restored, version /'; rm -rf "$tmp"
$K -n $NS patch externalsecret llm-key-only --type merge -p '{"spec":{"target":{"deletionPolicy":"Retain"}}}' >/dev/null
sync2 trellis-secrets-static; sync2 llm-key-only; sleep 20
echo "   final: static=$(es2 trellis-secrets-static)/$(k2 trellis-secrets-static TRELLIS_LLM_API_KEY) single=$(es2 llm-key-only)/$(k2 llm-key-only TRELLIS_LLM_API_KEY)"
$F resume kustomization secret-lab-aws --timeout 3m >/dev/null 2>&1
echo "AWS rows end=$(now)"
