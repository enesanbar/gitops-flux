#!/usr/bin/env bash
# The base AWS setup for the Parameter Store experiments, in dependency order. Run it in your own
# shell with an SSO profile; step 7 writes the one access key to a 0600 file, never to the terminal.
set -euo pipefail
: "${AWS_PROFILE:?export AWS_PROFILE=<your sso profile>}"
REGION="${REGION:-us-west-1}"           # the region the experiments use
PREFIX="${PREFIX:-/lab-cluster00}"      # must match the manifests: /lab-cluster00/trellis/..., /lab-cluster00/tls/...
USER_NAME=eso-groundwork-lab; ROLE_NAME=eso-groundwork-reader; POLICY_NAME=eso-groundwork-experiment; KEY_ALIAS=alias/eso-groundwork
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
echo "account=$ACCOUNT region=$REGION prefix=$PREFIX"

echo "== 1. IAM user (no permissions yet) =="
aws iam create-user --user-name "$USER_NAME" --tags Key=purpose,Value=eso-groundwork >/dev/null 2>&1 || echo "   user exists"

echo "== 2. Read-only role the user may assume (the Vault-minted shape) =="
cat > /tmp/eso-trust.json <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::${ACCOUNT}:user/${USER_NAME}"},"Action":"sts:AssumeRole"}]}
JSON
aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document file:///tmp/eso-trust.json --max-session-duration 3600 >/dev/null 2>&1 || echo "   role exists"

echo "== 3. Customer-managed KMS key for the SecureString-with-KMS case =="
KEY_ID=$(aws kms describe-key --key-id "$KEY_ALIAS" --region "$REGION" --query KeyMetadata.KeyId --output text 2>/dev/null || true)
if [ -z "$KEY_ID" ]; then
  KEY_ID=$(aws kms create-key --region "$REGION" --description "ESO groundwork lab" --query KeyMetadata.KeyId --output text)
  aws kms create-alias --region "$REGION" --alias-name "$KEY_ALIAS" --target-key-id "$KEY_ID"
fi
KEY_ARN="arn:aws:kms:${REGION}:${ACCOUNT}:key/${KEY_ID}"; echo "   key=$KEY_ARN"

echo "== 4. The user's policy: read + experiment writes on the prefix, find-by-tag on *, the key, assume the role =="
cat > /tmp/eso-user-policy.json <<JSON
{"Version":"2012-10-17","Statement":[
 {"Sid":"ReadPrefix","Effect":"Allow","Action":["ssm:GetParameter","ssm:GetParameters","ssm:GetParametersByPath","ssm:GetParameterHistory","ssm:ListTagsForResource"],"Resource":"arn:aws:ssm:${REGION}:${ACCOUNT}:parameter${PREFIX}/*"},
 {"Sid":"WritePrefixForExperiments","Effect":"Allow","Action":["ssm:PutParameter","ssm:DeleteParameter","ssm:DeleteParameters","ssm:LabelParameterVersion","ssm:AddTagsToResource","ssm:RemoveTagsFromResource"],"Resource":"arn:aws:ssm:${REGION}:${ACCOUNT}:parameter${PREFIX}/*"},
 {"Sid":"FindByTagNeedsStar","Effect":"Allow","Action":["ssm:DescribeParameters","tag:GetResources"],"Resource":"*"},
 {"Sid":"CustomerKeyForSecureString","Effect":"Allow","Action":["kms:Decrypt","kms:Encrypt","kms:GenerateDataKey","kms:DescribeKey"],"Resource":"${KEY_ARN}"},
 {"Sid":"AssumeReaderForVaultMinted","Effect":"Allow","Action":"sts:AssumeRole","Resource":"arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}"}]}
JSON
POLICY_ARN="arn:aws:iam::${ACCOUNT}:policy/${POLICY_NAME}"
aws iam create-policy --policy-name "$POLICY_NAME" --policy-document file:///tmp/eso-user-policy.json >/dev/null 2>&1 || echo "   policy exists (delete it first if you changed the document)"
aws iam attach-user-policy --user-name "$USER_NAME" --policy-arn "$POLICY_ARN"

echo "== 5. The reader role's policy: read-only on the prefix, find-by-tag, decrypt with the key =="
cat > /tmp/eso-reader-policy.json <<JSON
{"Version":"2012-10-17","Statement":[
 {"Sid":"ReadPrefix","Effect":"Allow","Action":["ssm:GetParameter","ssm:GetParameters","ssm:GetParametersByPath","ssm:GetParameterHistory","ssm:ListTagsForResource"],"Resource":"arn:aws:ssm:${REGION}:${ACCOUNT}:parameter${PREFIX}/*"},
 {"Sid":"FindByTagNeedsStar","Effect":"Allow","Action":["ssm:DescribeParameters","tag:GetResources"],"Resource":"*"},
 {"Sid":"DecryptOnly","Effect":"Allow","Action":["kms:Decrypt","kms:DescribeKey"],"Resource":"${KEY_ARN}"}]}
JSON
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name eso-groundwork-reader --policy-document file:///tmp/eso-reader-policy.json

echo "== 6. Sanity: what the user may do (no key created yet) =="
aws iam list-attached-user-policies --user-name "$USER_NAME" --output table
aws iam get-role --role-name "$ROLE_NAME" --query 'Role.{Arn:Arn,MaxSession:MaxSessionDuration}' --output table

echo "== 7. ONE access key, written to a 0600 file rather than to this terminal =="
OUT="${SECRET_STATE_DIR:-$HOME/.eso-groundwork}"; mkdir -p "$OUT"; chmod 700 "$OUT"
umask 077
aws iam create-access-key --user-name "$USER_NAME" --query 'AccessKey.{id:AccessKeyId,secret:SecretAccessKey}' --output json > "$OUT/new-access-key.json"
chmod 600 "$OUT/new-access-key.json"
echo "   written to $OUT/new-access-key.json (id and secret; nothing was printed)"
echo "   next: aws-credentials.sh import $REGION arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}"
echo "   the import prompts hide what you paste; read the two values from that file, then delete it."
rm -f /tmp/eso-trust.json /tmp/eso-user-policy.json /tmp/eso-reader-policy.json

# ---------------------------------------------------------------------------------------------
# Teardown. Run when the experiment is over; it reverses steps 1-7 in dependency order. The KMS key
# cannot be deleted immediately, only scheduled (7 days is the minimum AWS allows).
#   TEARDOWN=1 base-iam.sh
# ---------------------------------------------------------------------------------------------
if [ "${TEARDOWN:-}" = "1" ]; then
  echo "== teardown =="
  for k in $(aws iam list-access-keys --user-name "$USER_NAME" --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null); do
    aws iam delete-access-key --user-name "$USER_NAME" --access-key-id "$k" && echo "   access key deleted"
  done
  aws iam detach-user-policy --user-name "$USER_NAME" --policy-arn "$POLICY_ARN" 2>/dev/null && echo "   policy detached"
  aws iam delete-policy --policy-arn "$POLICY_ARN" 2>/dev/null && echo "   policy deleted"
  aws iam delete-user --user-name "$USER_NAME" 2>/dev/null && echo "   user deleted"
  aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$ROLE_NAME" 2>/dev/null && echo "   role policy deleted"
  aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null && echo "   role deleted"
  for p in $(aws ssm describe-parameters --parameter-filters "Key=Path,Values=${PREFIX}/,Option=Recursive" --region "$REGION" --query 'Parameters[].Name' --output text 2>/dev/null); do
    aws ssm delete-parameter --name "$p" --region "$REGION" && echo "   parameter $p deleted"
  done
  aws kms delete-alias --alias-name "$KEY_ALIAS" --region "$REGION" 2>/dev/null && echo "   key alias deleted"
  aws kms schedule-key-deletion --key-id "$KEY_ID" --pending-window-in-days 7 --region "$REGION" >/dev/null 2>&1 && echo "   key scheduled for deletion in 7 days"
  echo "teardown done"
fi
