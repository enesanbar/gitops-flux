#!/usr/bin/env bash
# Developer friction, AWS half: add a brand-new secret end to end the way a developer would under
# GitOps, then rotate it. Mirrors r14-developer-friction.sh so the two backends compare on equal work.
source "$(dirname "$0")/lib.sh"; NS=secret-lab-aws; cd "$W"
export AWS_DEFAULT_REGION=$(jq -r .region "$SECRET_STATE_DIR/aws/config.json")
export AWS_ACCESS_KEY_ID="$(cat "$SECRET_STATE_DIR/aws/access_key_id")" AWS_SECRET_ACCESS_KEY="$(cat "$SECRET_STATE_DIR/aws/secret_access_key")"
unset AWS_PROFILE AWS_SESSION_TOKEN
k2() { $K -n $NS get secret "$1" -o go-template="{{with index .data \"$2\"}}{{len .}}{{else}}absent{{end}}" 2>/dev/null || echo no-secret; }
echo "AWS developer friction start=$(now)"; T0=$(date -u +%s)
echo "step 1 (operator/dev): write the parameter (SecureString, default key)"
tmp=$(mktemp -d "$SECRET_STATE_DIR/.aws-friction.XXXXXX")
jq -n --arg v "$(openssl rand -base64 32 | tr -d '\n')" '{Name:"/lab-cluster00/trellis/embedding",Type:"SecureString",Value:$v,Overwrite:true}' > "$tmp/put.json"; chmod 600 "$tmp/put.json"
aws ssm put-parameter --cli-input-json "file://$tmp/put.json" --query Version --output text | sed 's/^/   version /'; echo "   $(el)"
echo "step 2 (dev): add three lines to the ExternalSecret in git"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path("components/secret-lab-aws/external-secrets.yaml"); t = p.read_text()
if "TRELLIS_EMBEDDING_API_KEY" in t:
    print("   already present, leaving the file alone"); sys.exit(0)
old = """  - secretKey: TRELLIS_LLM_API_KEY
    remoteRef:
      key: /lab-cluster00/trellis/llm
---
# Single-parameter mapping."""
assert t.count(old) == 1
p.write_text(t.replace(old, """  - secretKey: TRELLIS_LLM_API_KEY
    remoteRef:
      key: /lab-cluster00/trellis/llm
  - secretKey: TRELLIS_EMBEDDING_API_KEY
    remoteRef:
      key: /lab-cluster00/trellis/embedding
---
# Single-parameter mapping."""))
PY
kubectl kustomize components/secret-lab-aws >/dev/null && echo "   render ok $(el)"
echo "step 3 (dev): commit and push — NOT done by this script (a measurement must not write shared history)"
git --no-pager diff --stat components/secret-lab-aws/external-secrets.yaml | sed 's/^/   /'
echo "   commit it, then the reconcile below is step 4. $(el)"
echo "step 4: wait for Flux, or reconcile by hand"
$F reconcile kustomization secret-lab-aws --with-source --timeout 3m 2>&1 | tail -1 | sed 's/^/   /'; echo "   $(el)"
echo "step 5: [wait began $(el)] the Secret carries the key: $(waitfor 180 "k2 trellis-secrets-static TRELLIS_EMBEDDING_API_KEY" 60)"
echo "ROTATION: put a length-distinguishable value and wait for the 1m interval"
T0=$(date -u +%s)
jq -n --arg v "$(openssl rand -base64 60 | tr -d '\n')" '{Name:"/lab-cluster00/trellis/embedding",Type:"SecureString",Value:$v,Overwrite:true}' > "$tmp/put.json"; chmod 600 "$tmp/put.json"
aws ssm put-parameter --cli-input-json "file://$tmp/put.json" --query Version --output text | sed 's/^/   version /'
echo "   [wait began $(el)] Secret carries the longer value: $(waitfor 180 "k2 trellis-secrets-static TRELLIS_EMBEDDING_API_KEY" 108)"
rm -rf "$tmp"
echo "AWS friction end=$(now); steps to add: 6, same as the Vault half, with one put-parameter in place of one kv put"
