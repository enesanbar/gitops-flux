#!/usr/bin/env bash
# The AWS side of the tenant-credential stand-in, on top of base-iam.sh (the experiment user, its
# managed policy and the KMS key). A tenant cluster is handed one credential it did not create; this
# makes the lab equivalent: a user that reads the cluster's realm and one realm another team owns,
# with two access keys written straight to custody so a rotation can be rehearsed for real.
#
#   export SECRET_STATE_DIR=<the main tree's .local/secret-management/dev-cluster>
#   AWS_PROFILE=<IAM-admin profile of the lab account> tenant-iam.sh plan | apply | teardown
#
# Nothing secret is printed. `plan` changes nothing; `apply` and `teardown` ask before acting. The
# account must be the one custody's config.json names; once that file is gone, EXPECTED_ACCOUNT (and
# LAB_REGION if not us-west-1) name it instead.
set +x; set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/common.sh"
: "${AWS_PROFILE:?export AWS_PROFILE=<IAM-admin profile of the lab account>}"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN   # exported keys would win over the profile
export AWS_PAGER=""

REALM=/devops/dev-cluster   # the cluster's own subtree: /devops/<cluster>/<namespace>/...
FOREIGN=/dev-generic        # a realm another team owns: the stand-in only reads it; the lab user writes it for that team
BASE_PREFIX=/lab-cluster00  # base-iam.sh's prefix, which this script never touches
LAB_USER=eso-groundwork-lab LAB_POLICY=eso-groundwork-experiment KEY_ALIAS=alias/eso-groundwork
TENANT_USER=eso-lab-tenant TENANT_POLICY=eso-lab-tenant-read
CONFIG="${SECRET_STATE_DIR}/aws/config.json"
TENANT_CUSTODY="${SECRET_STATE_DIR}/aws/tenant"
PENDING_KEY=""

die() { echo "$*" >&2; exit 1; }
confirm() { local ok; read -r -p "$1 [y/N] " ok; [ "$ok" = y ] || die "Nothing changed."; }

# present | absent. Only a not-found error means absent; any other failure stops the script, because
# teardown deletes the custody copies of the keys once the user reads as absent.
state_of() {
  local out
  if out=$("$@" 2>&1 >/dev/null); then echo present; return; fi
  case "$out" in *NoSuchEntity*|*NotFoundException*) echo absent ;; *) echo "${out:-$* failed}" >&2; return 1 ;; esac
}

identity() {
  local expected
  if [ -s "$CONFIG" ]; then
    expected=$(jq -r '.reader_role_arn | split(":")[4]' "$CONFIG")
    REGION=$(jq -r .region "$CONFIG")
  else
    : "${EXPECTED_ACCOUNT:?custody has no config.json; export EXPECTED_ACCOUNT to name the lab account}"
    expected=$EXPECTED_ACCOUNT REGION=${LAB_REGION:-us-west-1}
  fi
  CALLER=$(aws sts get-caller-identity --query Arn --output text)
  ACCOUNT=$(printf '%s' "$CALLER" | cut -d: -f5)
  [ "$ACCOUNT" = "$expected" ] || die "Profile $AWS_PROFILE is account $ACCOUNT; the lab's custody names $expected."
  LAB_POLICY_ARN="arn:aws:iam::${ACCOUNT}:policy/${LAB_POLICY}"
  SSM_ARN="arn:aws:ssm:${REGION}:${ACCOUNT}:parameter"
}

needs_base() {
  local state
  state=$(state_of aws iam get-user --user-name "$LAB_USER")
  [ "$state" = present ] || die "No user $LAB_USER in account $ACCOUNT: base-iam.sh never ran here."
  KEY_ARN=$(aws kms describe-key --key-id "$KEY_ALIAS" --region "$REGION" --query KeyMetadata.Arn --output text)
}

current_lab_policy() {
  local version
  version=$(aws iam get-policy --policy-arn "$LAB_POLICY_ARN" --query Policy.DefaultVersionId --output text)
  aws iam get-policy-version --policy-arn "$LAB_POLICY_ARN" --version-id "$version" \
    --query PolicyVersion.Document --output json
}

# widen | narrow. The realms get statements of their own, so the base statements are never edited
# and hardening applied to them by hand, since base-iam.sh ran, stays as it is. Both directions first
# strip the realm ARNs from every other statement, which undoes the in-place widening an earlier
# version of this script did. Either direction applied twice changes nothing.
reshape_lab_policy() {
  jq -S --arg mode "$1" --arg realm "${SSM_ARN}${REALM}/*" --arg foreign "${SSM_ARN}${FOREIGN}/*" \
    --arg key "${KEY_ARN:-}" --arg via "ssm.${REGION}.amazonaws.com" \
    --arg tenant "arn:aws:iam::${ACCOUNT}:user/${TENANT_USER}" '
    def arr: if type == "array" then . else [.] end;
    def one: if length == 1 then .[0] else . end;
    def ours: ["TenantShapeRealms", "TenantShapeKey", "ToggleTenantKeys"];
    .Statement |= (map(select((.Sid // "") as $sid | ours | any(. == $sid) | not))
      | map(if any(.Resource | arr | .[]; . == $realm or . == $foreign)
            then .Resource = ((.Resource | arr) - [$realm, $foreign] | one) else . end)
      + (if $mode == "widen" then [
          {Sid: "TenantShapeRealms", Effect: "Allow", Resource: [$realm, $foreign],
           Action: ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:GetParameterHistory",
                    "ssm:ListTagsForResource", "ssm:PutParameter", "ssm:DeleteParameter", "ssm:DeleteParameters",
                    "ssm:LabelParameterVersion", "ssm:AddTagsToResource", "ssm:RemoveTagsFromResource"]},
          {Sid: "TenantShapeKey", Effect: "Allow", Resource: $key,
           Action: ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey"],
           Condition: {StringEquals: {"kms:ViaService": $via}}},
          # Lab-only: the lab key also sits in the cluster (secret-lab-aws/aws-credentials), so this
          # hands an in-cluster credential an IAM write. It may activate and deactivate the keys of the
          # stand-in for the rotation rows and never create one; no tenant credential holds anything like it.
          {Sid: "ToggleTenantKeys", Effect: "Allow", Resource: $tenant,
           Action: ["iam:ListAccessKeys", "iam:UpdateAccessKey"]}] else [] end))'
}

# Every AWS answer is assigned before it is used: inside an argument, as in `echo "$(aws ...)"` or
# `[ "$(aws ...)" -ge 5 ]`, a failed call is not fatal and reads as an empty answer.
set_lab_policy() {
  local cur new count oldest version
  cur=$(current_lab_policy | jq -S -c .)
  new=$(printf '%s' "$cur" | reshape_lab_policy "$1" | jq -S -c .)
  if [ "$cur" = "$new" ]; then echo "   $LAB_POLICY unchanged"; return; fi
  count=$(aws iam list-policy-versions --policy-arn "$LAB_POLICY_ARN" --query 'length(Versions)' --output text)
  if [ "$count" -ge 5 ]; then   # a managed policy holds at most five versions
    oldest=$(aws iam list-policy-versions --policy-arn "$LAB_POLICY_ARN" \
      --query 'sort_by(Versions[?!IsDefaultVersion], &CreateDate)[0].VersionId' --output text)
    aws iam delete-policy-version --policy-arn "$LAB_POLICY_ARN" --version-id "$oldest"
  fi
  version=$(aws iam create-policy-version --policy-arn "$LAB_POLICY_ARN" \
    --policy-document "$new" --set-as-default --query PolicyVersion.VersionId --output text)
  echo "   $LAB_POLICY now at $version"
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

# Only a user this script made is adopted: a broader leftover would void the narrow stand-in.
refuse_foreign_user() {
  local tag attached groups inline
  tag=$(aws iam list-user-tags --user-name "$TENANT_USER" --query "Tags[?Key=='stands-in-for'].Value | [0]" --output text)
  attached=$(aws iam list-attached-user-policies --user-name "$TENANT_USER" --query 'length(AttachedPolicies)' --output text)
  groups=$(aws iam list-groups-for-user --user-name "$TENANT_USER" --query 'length(Groups)' --output text)
  inline=$(aws iam list-user-policies --user-name "$TENANT_USER" --query "length(PolicyNames[?@ != '$TENANT_POLICY'])" --output text)
  [ "$tag" = tenant-credential ] && [ "$attached" = 0 ] && [ "$groups" = 0 ] && [ "$inline" = 0 ] ||
    die "$TENANT_USER exists but is not the narrow stand-in this script makes; not adopting it."
}

key_ids() { aws iam list-access-keys --user-name "$TENANT_USER" --query 'AccessKeyMetadata[].AccessKeyId' --output text; }
slot_id() { cat "${TENANT_CUSTODY}/$1/access_key_id" 2>/dev/null || true; }   # the key id, never the secret

# AWS never returns a secret twice, so a key minted by a run that then fails is useless: the exit
# trap deletes it instead of leaving it for the next apply to trip over.
drop_pending_key() {
  [ -n "$PENDING_KEY" ] || return 0
  aws iam delete-access-key --user-name "$TENANT_USER" --access-key-id "$PENDING_KEY" &&
    echo "   the key this failed run minted was deleted again" >&2
}
trap drop_pending_key EXIT
trap 'exit 130' INT TERM

create_key_into() {
  local json
  json=$(aws iam create-access-key --user-name "$TENANT_USER" --output json)
  PENDING_KEY=$(printf '%s' "$json" | jq -r .AccessKey.AccessKeyId)
  printf '%s' "$json" | jq -j .AccessKey.AccessKeyId | private_write "${TENANT_CUSTODY}/$1/access_key_id"
  printf '%s' "$json" | jq -j .AccessKey.SecretAccessKey | private_write "${TENANT_CUSTODY}/$1/secret_access_key"
  PENDING_KEY=""
}

ensure_keys() {
  local ids slot id held=" " missing=() orphans=()
  ids=$(key_ids)
  [ "$ids" = None ] && ids=""
  for slot in a b; do
    id=$(slot_id "$slot")
    if [ -n "$id" ] && [ -s "${TENANT_CUSTODY}/$slot/secret_access_key" ] && [[ " ${ids//$'\t'/ } " == *" $id "* ]]
    then held+="$id "; else missing+=("$slot"); fi
  done
  for id in $ids; do [[ $held == *" $id "* ]] || orphans+=("$id"); done
  [ "${#orphans[@]}" = 0 ] || die "$TENANT_USER has key(s) ${orphans[*]} whose secret custody does not hold,
and AWS cannot return it: aws iam delete-access-key --user-name $TENANT_USER --access-key-id <id>, then apply
again. Not teardown: it also deletes every parameter under both realms."
  if [ "${#missing[@]}" = 0 ]; then echo "   both keys already in custody"; return; fi
  for slot in "${missing[@]}"; do create_key_into "$slot"; echo "   key $slot written to custody"; done
}

plan() {
  local cur widened state ids count
  cur=$(current_lab_policy | jq -S .)
  widened=$(printf '%s' "$cur" | reshape_lab_policy widen | jq -S .)
  echo "caller=$CALLER region=$REGION"
  echo "== $LAB_POLICY, current default -> widened"
  diff <(printf '%s\n' "$cur") <(printf '%s\n' "$widened") || true
  state=$(state_of aws iam get-user --user-name "$TENANT_USER")
  if [ "$state" = present ]; then
    ids=$(key_ids); [ "$ids" = None ] && ids=""
    count=$(wc -w <<<"$ids" | tr -d ' ')
    echo "== $TENANT_USER exists with $count key(s)"
  else echo "== $TENANT_USER to be created"; fi
  echo "== $TENANT_POLICY (inline on $TENANT_USER)"; tenant_policy | jq .
  echo "Untouched: the reader role, the KMS key and its policy, ${BASE_PREFIX}/*, the lab user's own key."
}

apply() {
  local state history
  [ -s "$CONFIG" ] || die "No lab AWS custody at $CONFIG; point SECRET_STATE_DIR at the main tree's .local/secret-management/dev-cluster."
  # With it on, the CLI records every response, a new key's secret included, in ~/.aws/cli/history.
  history=$(aws configure get cli_history 2>/dev/null || true)
  [ "$history" != enabled ] || die "cli_history is enabled for $AWS_PROFILE; turn it off before apply mints keys."
  plan
  confirm "Apply to account $ACCOUNT?"
  echo "== 1. $LAB_POLICY"; set_lab_policy widen
  echo "== 2. $TENANT_USER and $TENANT_POLICY"
  state=$(state_of aws iam get-user --user-name "$TENANT_USER")
  if [ "$state" = absent ]; then
    aws iam create-user --user-name "$TENANT_USER" \
      --tags Key=purpose,Value=eso-groundwork Key=stands-in-for,Value=tenant-credential >/dev/null
    aws iam wait user-exists --user-name "$TENANT_USER"
  else
    refuse_foreign_user
  fi
  aws iam put-user-policy --user-name "$TENANT_USER" --policy-name "$TENANT_POLICY" --policy-document "$(tenant_policy)"
  echo "== 3. access keys"; ensure_keys
  echo "Done. Parameters are written with the lab user's key; the stand-in only reads."
}

# Needs no base resources, so it still works after base-iam.sh is gone. The user goes first and must
# read as absent before custody is touched; the policy is narrowed before the sweep, so the lab key
# cannot write a parameter the listing has already passed.
teardown() {
  local state ids key names name prefix
  echo "caller=$CALLER: deletes $TENANT_USER and its keys, narrows $LAB_POLICY, then deletes every"
  echo "parameter under ${REALM}/ and ${FOREIGN}/ and the tenant keys in custody."
  confirm "Tear down in account $ACCOUNT?"
  state=$(state_of aws iam get-user --user-name "$TENANT_USER")
  if [ "$state" = present ]; then
    ids=$(key_ids)
    for key in $ids; do
      [ "$key" = None ] || aws iam delete-access-key --user-name "$TENANT_USER" --access-key-id "$key"
    done
    state=$(state_of aws iam get-user-policy --user-name "$TENANT_USER" --policy-name "$TENANT_POLICY")
    [ "$state" = absent ] || aws iam delete-user-policy --user-name "$TENANT_USER" --policy-name "$TENANT_POLICY"
    aws iam delete-user --user-name "$TENANT_USER"
  fi
  state=$(state_of aws iam get-user --user-name "$TENANT_USER")
  [ "$state" = absent ] || die "$TENANT_USER still exists; custody keeps its keys."
  echo "   $TENANT_USER gone"
  state=$(state_of aws iam get-policy --policy-arn "$LAB_POLICY_ARN")
  if [ "$state" = present ]; then echo "== $LAB_POLICY"; set_lab_policy narrow
  else echo "   $LAB_POLICY already gone"; fi
  for prefix in "$REALM" "$FOREIGN"; do
    names=$(aws ssm describe-parameters --region "$REGION" \
      --parameter-filters "Key=Path,Option=Recursive,Values=${prefix}" --query 'Parameters[].Name' --output text)
    for name in $names; do
      [ "$name" = None ] && continue
      aws ssm delete-parameter --region "$REGION" --name "$name"
      echo "   $name deleted"
    done
  done
  rm -rf -- "${SECRET_STATE_DIR:?}/aws/tenant"
  echo "   tenant keys removed from custody"
  echo "The cluster side is separate: aws-credentials.sh tenant-remove."
}

case "${1:-}" in
  plan) identity; needs_base; plan ;;
  apply) identity; needs_base; apply ;;
  teardown) identity; teardown ;;
  *) echo "Usage: tenant-iam.sh plan | apply | teardown" >&2; exit 2 ;;
esac
