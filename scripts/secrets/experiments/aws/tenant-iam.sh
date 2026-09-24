#!/usr/bin/env bash
# The AWS side of the tenant-credential stand-in, on top of base-iam.sh (the experiment user, its
# managed policy and the KMS key). A tenant cluster is handed one credential it did not create; this
# makes the lab equivalent: a user that reads the cluster's realm and one realm another team owns,
# with two access keys written straight to custody so a rotation can be rehearsed for real.
#
#   export SECRET_STATE_DIR=<the main tree's .local/secret-management/dev-cluster>
#   AWS_PROFILE=<IAM-admin profile of the lab account> tenant-iam.sh plan | apply | teardown
#
# Nothing secret is printed. `plan` changes nothing; `apply` and `teardown` ask before acting.
set +x; set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/common.sh"
: "${AWS_PROFILE:?export AWS_PROFILE=<IAM-admin profile of the lab account>}"
export AWS_PAGER=""

REGION="${REGION:-us-west-1}"
REALM=/devops/dev-cluster   # the cluster's own subtree: /devops/<cluster>/<namespace>/...
FOREIGN=/dev-generic        # a realm another team owns; the cluster reads it and never writes it
BASE_PREFIX=/lab-cluster00  # base-iam.sh's prefix: every statement granting it also gains the two above
LAB_USER=eso-groundwork-lab LAB_POLICY=eso-groundwork-experiment KEY_ALIAS=alias/eso-groundwork
TENANT_USER=eso-lab-tenant TENANT_POLICY=eso-lab-tenant-read
TENANT_CUSTODY="${SECRET_STATE_DIR}/aws/tenant"

die() { echo "$*" >&2; exit 1; }
confirm() { local ok; read -r -p "$1 [y/N] " ok; [ "$ok" = y ] || die "Nothing changed."; }
exists_user() { aws iam get-user --user-name "$1" >/dev/null 2>&1; }

preflight() {
  [ -s "${SECRET_STATE_DIR}/aws/config.json" ] ||
    die "No lab AWS custody under SECRET_STATE_DIR; point it at the main tree's .local/secret-management/dev-cluster."
  ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
  # base-iam.sh's resources double as the account's fingerprint, so an admin profile for any other
  # account stops here before anything is created in it.
  exists_user "$LAB_USER" || die "No user $LAB_USER in account $ACCOUNT: wrong profile, or base-iam.sh never ran."
  KEY_ARN=$(aws kms describe-key --key-id "$KEY_ALIAS" --region "$REGION" --query KeyMetadata.Arn --output text 2>/dev/null) ||
    die "No $KEY_ALIAS in $REGION of account $ACCOUNT."
  LAB_POLICY_ARN="arn:aws:iam::${ACCOUNT}:policy/${LAB_POLICY}"
  SSM_ARN="arn:aws:ssm:${REGION}:${ACCOUNT}:parameter"
}

current_lab_policy() {
  local version
  version=$(aws iam get-policy --policy-arn "$LAB_POLICY_ARN" --query Policy.DefaultVersionId --output text)
  aws iam get-policy-version --policy-arn "$LAB_POLICY_ARN" --version-id "$version" \
    --query PolicyVersion.Document --output json
}

# widen | narrow, applied to the live document rather than to a copy of it, so a statement hardened
# by hand since base-iam.sh ran keeps its hardening. Either direction applied twice changes nothing.
reshape_lab_policy() {
  jq -S --arg mode "$1" --arg base "${SSM_ARN}${BASE_PREFIX}/*" \
    --arg realm "${SSM_ARN}${REALM}/*" --arg foreign "${SSM_ARN}${FOREIGN}/*" \
    --arg tenant "arn:aws:iam::${ACCOUNT}:user/${TENANT_USER}" '
    def arr: if type == "array" then . else [.] end;
    def one: if length == 1 then .[0] else . end;
    .Statement |= (map(select(.Sid != "ToggleTenantKeys"))
      | map(if any(.Resource | arr | .[]; . == $base)
            then .Resource = (((.Resource | arr) - [$realm, $foreign])
                              + (if $mode == "widen" then [$realm, $foreign] else [] end) | one)
            else . end)
      # Lab-only: the lab key also sits in the cluster (secret-lab-aws/aws-credentials), so this hands
      # an in-cluster credential an IAM write. It may activate and deactivate the keys of the stand-in
      # for the rotation rows and never create one; no tenant credential holds anything like it.
      + (if $mode == "widen" then [{Sid: "ToggleTenantKeys", Effect: "Allow",
            Action: ["iam:ListAccessKeys", "iam:UpdateAccessKey"], Resource: $tenant}] else [] end))'
}

set_lab_policy() {
  local cur new oldest
  cur=$(current_lab_policy | jq -S -c .)
  new=$(printf '%s' "$cur" | reshape_lab_policy "$1" | jq -S -c .)
  if [ "$cur" = "$new" ]; then echo "   $LAB_POLICY unchanged"; return; fi
  # A managed policy holds at most five versions.
  if [ "$(aws iam list-policy-versions --policy-arn "$LAB_POLICY_ARN" --query 'length(Versions)' --output text)" -ge 5 ]; then
    oldest=$(aws iam list-policy-versions --policy-arn "$LAB_POLICY_ARN" \
      --query 'sort_by(Versions[?!IsDefaultVersion], &CreateDate)[0].VersionId' --output text)
    aws iam delete-policy-version --policy-arn "$LAB_POLICY_ARN" --version-id "$oldest"
  fi
  echo "   $LAB_POLICY now at $(aws iam create-policy-version --policy-arn "$LAB_POLICY_ARN" \
    --policy-document "$new" --set-as-default --query PolicyVersion.VersionId --output text)"
}

# ssm:GetParameter (every call the operator makes for data[], remoteRef.property, dataFrom.extract
# and a name:version pin) on the two realms, and nothing else. A production tenant credential may be
# broader, so an AccessDenied measured here (a find, a read outside the realms) belongs to this lab.
tenant_policy() {
  jq -n -c --arg realm "${SSM_ARN}${REALM}/*" --arg foreign "${SSM_ARN}${FOREIGN}/*" \
    --arg key "$KEY_ARN" --arg via "ssm.${REGION}.amazonaws.com" '{Version: "2012-10-17", Statement: [
      {Sid: "ReadOwnAndForeignRealm", Effect: "Allow", Action: "ssm:GetParameter", Resource: [$realm, $foreign]},
      {Sid: "DecryptThroughParameterStoreOnly", Effect: "Allow", Action: "kms:Decrypt", Resource: $key,
       Condition: {StringEquals: {"kms:ViaService": $via}}}]}'
}

key_count() { aws iam list-access-keys --user-name "$TENANT_USER" --query 'length(AccessKeyMetadata)' --output text; }
slot_held() { [ -s "${TENANT_CUSTODY}/$1/access_key_id" ] && [ -s "${TENANT_CUSTODY}/$1/secret_access_key" ]; }

# The secret half exists only in this one response, so it goes straight to custody.
create_key_into() {
  local json
  json=$(aws iam create-access-key --user-name "$TENANT_USER" --output json)
  printf '%s' "$json" | jq -j .AccessKey.AccessKeyId | private_write "${TENANT_CUSTODY}/$1/access_key_id"
  printf '%s' "$json" | jq -j .AccessKey.SecretAccessKey | private_write "${TENANT_CUSTODY}/$1/secret_access_key"
}

ensure_keys() {
  local count
  count=$(key_count)
  if [ "$count" = 2 ] && slot_held a && slot_held b; then echo "   both keys already in custody"; return; fi
  [ "$count" = 0 ] || die "$TENANT_USER has $count key(s) whose secrets custody does not hold and AWS cannot return:
delete them (aws iam list-access-keys / delete-access-key --user-name $TENANT_USER), then apply again.
Not teardown: it also deletes every parameter under both realms."
  create_key_into a
  create_key_into b
  echo "   two access keys written to custody as tenant/a and tenant/b"
}

plan() {
  echo "account=$ACCOUNT region=$REGION profile=$AWS_PROFILE"
  echo "== $LAB_POLICY, current default -> widened"
  diff <(current_lab_policy | jq -S .) <(current_lab_policy | reshape_lab_policy widen | jq -S .) || true
  if exists_user "$TENANT_USER"; then echo "== $TENANT_USER exists with $(key_count) key(s)"
  else echo "== $TENANT_USER to be created"; fi
  echo "== $TENANT_POLICY (inline on $TENANT_USER)"; tenant_policy | jq .
  echo "Untouched: the reader role, the KMS key and its policy, ${BASE_PREFIX}/*, the lab user's own key."
}

apply() {
  plan
  confirm "Apply to account $ACCOUNT?"
  echo "== 1. $LAB_POLICY"; set_lab_policy widen
  echo "== 2. $TENANT_USER and $TENANT_POLICY"
  exists_user "$TENANT_USER" || aws iam create-user --user-name "$TENANT_USER" \
    --tags Key=purpose,Value=eso-groundwork Key=stands-in-for,Value=tenant-credential >/dev/null
  aws iam wait user-exists --user-name "$TENANT_USER"
  aws iam put-user-policy --user-name "$TENANT_USER" --policy-name "$TENANT_POLICY" --policy-document "$(tenant_policy)"
  echo "== 3. access keys"; ensure_keys
  echo "Done. Parameters are written with the lab user's key; the stand-in only reads."
}

teardown() {
  local names name key
  echo "account=$ACCOUNT: removes $TENANT_USER and its keys, every parameter under ${REALM}/ and ${FOREIGN}/,"
  echo "the tenant keys in custody, and the widening of $LAB_POLICY."
  confirm "Tear down in account $ACCOUNT?"
  if exists_user "$TENANT_USER"; then
    for key in $(aws iam list-access-keys --user-name "$TENANT_USER" --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
      aws iam delete-access-key --user-name "$TENANT_USER" --access-key-id "$key"
    done
    aws iam delete-user-policy --user-name "$TENANT_USER" --policy-name "$TENANT_POLICY" 2>/dev/null || true
    aws iam delete-user --user-name "$TENANT_USER"
    echo "   $TENANT_USER deleted"
  fi
  for prefix in "$REALM" "$FOREIGN"; do
    names=$(aws ssm describe-parameters --region "$REGION" \
      --parameter-filters "Key=Path,Option=Recursive,Values=${prefix}" --query 'Parameters[].Name' --output text)
    for name in $names; do
      [ "$name" = None ] && continue
      aws ssm delete-parameter --region "$REGION" --name "$name"
      echo "   $name deleted"
    done
  done
  echo "== $LAB_POLICY"; set_lab_policy narrow
  rm -rf -- "${SECRET_STATE_DIR:?}/aws/tenant"
  echo "   tenant keys removed from custody"
  echo "The cluster side is separate: delete external-secrets/aws-credentials in the lab."
}

case "${1:-}" in
  plan) preflight; plan ;;
  apply) preflight; apply ;;
  teardown) preflight; teardown ;;
  *) echo "Usage: tenant-iam.sh plan | apply | teardown" >&2; exit 2 ;;
esac
