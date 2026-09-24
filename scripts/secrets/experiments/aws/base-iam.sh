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
POLICY_ARN="arn:aws:iam::${ACCOUNT}:policy/${POLICY_NAME}"

# ---------------------------------------------------------------------------------------------
# Teardown. Run when the experiment is over; it reverses steps 1-7 and exits before they run.
# tenant-iam.sh teardown goes first, and this refuses while its user exists: once this user and key
# are gone, neither script could remove that user's keys and parameters. The KMS key cannot be
# deleted immediately, only scheduled (7 days is the minimum AWS allows).
#   TEARDOWN=1 base-iam.sh
# ---------------------------------------------------------------------------------------------
if [ "${TEARDOWN:-}" = "1" ]; then
  # present | absent: a not-found error means absent; any other error stops the teardown.
  state_of() { local out; if out=$("$@" 2>&1 >/dev/null); then echo present; return; fi
    case "$out" in *NoSuchEntity*|*NotFoundException*) echo absent ;; *) echo "${out:-$* failed}" >&2; return 1 ;; esac; }
  gone() { local out; out=$("$@" 2>&1 >/dev/null) && return 0
    case "$out" in *NoSuchEntity*|*NotFoundException*|*ParameterNotFound*) return 0 ;; *) echo "$out" >&2; exit 1 ;; esac; }
  # The sweep below deletes recursively with an admin profile: a stray exported PREFIX=/ would take
  # every parameter in the account with it.
  [ "$PREFIX" = /lab-cluster00 ] || { echo "Teardown sweeps ${PREFIX}; it refuses any prefix but /lab-cluster00." >&2; exit 1; }
  CONFIG="${SECRET_STATE_DIR:-}/aws/config.json"
  if [ -s "$CONFIG" ]; then
    EXPECTED=$(jq -r '.reader_role_arn | split(":")[4]' "$CONFIG")
    [ "$REGION" = "$(jq -r .region "$CONFIG")" ] || { echo "REGION=$REGION, but custody names $(jq -r .region "$CONFIG")." >&2; exit 1; }
  else
    # Without custody both are named explicitly: a stray REGION in the environment would tear down
    # the global IAM half and silently skip the regional half.
    EXPECTED="${EXPECTED_ACCOUNT:?export SECRET_STATE_DIR (the lab custody) or EXPECTED_ACCOUNT to name the lab account}"
    REGION="${LAB_REGION:?export LAB_REGION too: the region of the lab key and parameters}"
  fi
  [ "$ACCOUNT" = "$EXPECTED" ] || { echo "Profile $AWS_PROFILE is account $ACCOUNT; the lab is $EXPECTED." >&2; exit 1; }
  state=$(state_of aws iam get-user --user-name eso-lab-tenant)
  [ "$state" = absent ] || { echo "eso-lab-tenant still exists: run tenant-iam.sh teardown first." >&2; exit 1; }
  echo "== teardown =="
  KEY_ID=""
  state=$(state_of aws kms describe-key --key-id "$KEY_ALIAS" --region "$REGION")
  [ "$state" = present ] && KEY_ID=$(aws kms describe-key --key-id "$KEY_ALIAS" --region "$REGION" --query KeyMetadata.KeyId --output text)
  state=$(state_of aws iam get-user --user-name "$USER_NAME")
  if [ "$state" = present ]; then
    keys=$(aws iam list-access-keys --user-name "$USER_NAME" --query 'AccessKeyMetadata[].AccessKeyId' --output text)
    for k in $keys; do
      [ "$k" = None ] || { gone aws iam delete-access-key --user-name "$USER_NAME" --access-key-id "$k"; echo "   access key deleted"; }
    done
    gone aws iam detach-user-policy --user-name "$USER_NAME" --policy-arn "$POLICY_ARN"
  fi
  state=$(state_of aws iam get-policy --policy-arn "$POLICY_ARN")
  if [ "$state" = present ]; then
    versions=$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" --query 'Versions[?!IsDefaultVersion].VersionId' --output text)
    for v in $versions; do [ "$v" = None ] || gone aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$v"; done
    gone aws iam delete-policy --policy-arn "$POLICY_ARN"
    echo "   policy deleted"
  fi
  gone aws iam delete-user --user-name "$USER_NAME"; echo "   user gone"
  gone aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$ROLE_NAME"
  gone aws iam delete-role --role-name "$ROLE_NAME"; echo "   role gone"
  names=$(aws ssm describe-parameters --region "$REGION" --parameter-filters "Key=Path,Option=Recursive,Values=${PREFIX}" \
    --query 'Parameters[].Name' --output text)
  for p in $names; do [ "$p" = None ] || { gone aws ssm delete-parameter --region "$REGION" --name "$p"; echo "   parameter $p deleted"; }; done
  # Scheduled before its alias goes: an unscheduled key without an alias is found again only by list-keys.
  if [ -n "$KEY_ID" ]; then
    keystate=$(aws kms describe-key --key-id "$KEY_ID" --region "$REGION" --query KeyMetadata.KeyState --output text)
    # A run that failed after scheduling leaves the key pending; scheduling it again is refused.
    if [ "$keystate" != PendingDeletion ]; then
      aws kms schedule-key-deletion --key-id "$KEY_ID" --pending-window-in-days 7 --region "$REGION" >/dev/null
    fi
    echo "   key scheduled for deletion"
    gone aws kms delete-alias --alias-name "$KEY_ALIAS" --region "$REGION"
  fi
  echo "== residue (every line must read absent)"
  for check in "iam get-user --user-name $USER_NAME" "iam get-policy --policy-arn $POLICY_ARN" "iam get-role --role-name $ROLE_NAME"; do
    r=$(state_of aws $check) || r=ERROR   # $check splits into its arguments on purpose
    echo "   $r  $check"
  done
  r=$(state_of aws kms describe-key --key-id "$KEY_ALIAS" --region "$REGION") || r=ERROR
  echo "   $r  kms alias $KEY_ALIAS"
  n=$(aws ssm describe-parameters --region "$REGION" --parameter-filters "Key=Path,Option=Recursive,Values=${PREFIX}" \
    --output json | jq '.Parameters | length')
  [ "$n" = 0 ] && echo "   absent  parameters under ${PREFIX}" || echo "   $n parameters left under ${PREFIX}"
  echo "teardown done"
  exit 0
fi

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
# With it on, the CLI records every response, the new secret included, in ~/.aws/cli/history.
history=$(aws configure get cli_history 2>/dev/null || true)
[ "$history" != enabled ] || { echo "cli_history is enabled for $AWS_PROFILE; turn it off before minting a key." >&2; exit 1; }
aws iam create-access-key --user-name "$USER_NAME" --query 'AccessKey.{id:AccessKeyId,secret:SecretAccessKey}' --output json > "$OUT/new-access-key.json"
chmod 600 "$OUT/new-access-key.json"
echo "   written to $OUT/new-access-key.json (id and secret; nothing was printed)"
echo "   next: aws-credentials.sh import $REGION arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}"
echo "   the import prompts hide what you paste; read the two values from that file, then delete it."
rm -f /tmp/eso-trust.json /tmp/eso-user-policy.json /tmp/eso-reader-policy.json
