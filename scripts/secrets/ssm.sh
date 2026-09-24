#!/usr/bin/env bash
# Writes and inspects Parameter Store entries under the layout in docs/secret-management/CONVENTIONS.md:
#   /devops/<cluster>/<namespace>/[<segment>/...]<name>
# A value arrives on stdin and never on a command line; no subcommand prints a value.
#
#   ssm.sh check <name> [--foreign]                     the layout alone, no AWS call
#   ssm.sh put <name> --description <text> [--key-class] [--overwrite [--new-key-version]] [--exact] [--foreign]
#   ssm.sh list <prefix>                                names and metadata
#   ssm.sh describe <name>                              metadata, tags and version history
#   ssm.sh copy-tree <from-prefix> <to-prefix>          an application moving to another cluster
#
#   openssl rand -base64 32 | ssm.sh put /devops/dev-cluster/trellis/kek --key-class \
#     --description "Trellis KEK; generated here; rotates by the application's two-key rewrap"
#
# put strips ONE trailing newline, because `openssl rand ... |` and `echo ... |` end with one and
# a key stored with it is a different key; --exact keeps the bytes as they are.
set +x; set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
export AWS_PAGER=""

REALM=/devops
FOREIGN=/dev-generic   # stands in for a realm another team owns; written only with --foreign
KEY_ALIAS=alias/eso-groundwork
AWS_STATE="${SECRET_STATE_DIR}/aws"
SEGMENT='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'   # cluster, namespace and nesting are Kubernetes-style names
LEAF='^[a-z][a-z0-9_]*$'                     # snake_case: the name doubles as a template variable

die() { echo "$*" >&2; exit 1; }

check_name() {
  local name=$1 foreign=$2 rest parts part
  case "$name" in
    "$FOREIGN"/*)
      [ "$foreign" = 1 ] || die "$name: ${FOREIGN}/ belongs to another team; it is written only with --foreign."
      [[ ${name#"$FOREIGN"/} =~ $LEAF ]] || die "$name: that realm is flat, ${FOREIGN}/<snake_case_name>."
      return ;;
    "$REALM"/*) rest=${name#"$REALM"/} ;;
    *) die "$name: outside ${REALM}/." ;;
  esac
  IFS=/ read -r -a parts <<<"$rest"
  [ "${#parts[@]}" -ge 3 ] || die "$name: needs ${REALM}/<cluster>/<namespace>/<name> at least."
  [ "$(( ${#parts[@]} + 1 ))" -le 15 ] || die "$name: Parameter Store allows 15 levels at most."
  for part in "${parts[@]:0:${#parts[@]}-1}"; do
    [[ $part =~ $SEGMENT ]] && [ "${#part}" -le 63 ] ||
      die "$name: '$part' must be a lowercase Kubernetes-style name (letters, digits, '-')."
  done
  [[ ${parts[${#parts[@]}-1]} =~ $LEAF ]] || die "$name: '${parts[${#parts[@]}-1]}' must be snake_case."
}

# The lab writes with the experiment user's key from custody; the credentials reach the CLI through
# its environment, never its arguments.
aws_ssm() {
  (
    unset AWS_PROFILE AWS_DEFAULT_PROFILE
    AWS_ACCESS_KEY_ID="$(cat "${AWS_STATE}/access_key_id")"
    AWS_SECRET_ACCESS_KEY="$(cat "${AWS_STATE}/secret_access_key")"
    AWS_REGION="$(jq -r .region "${AWS_STATE}/config.json")"
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION
    aws ssm "$@"
  )
}

count_named() { aws_ssm describe-parameters --parameter-filters "Key=Name,Option=Equals,Values=$1" --query 'length(Parameters)' --output text; }
count_below() { aws_ssm describe-parameters --parameter-filters "Key=Path,Option=Recursive,Values=${1%/}" --query 'length(Parameters)' --output text; }
tag_value() { aws_ssm list-tags-for-resource --resource-type Parameter --resource-id "$1" --query "TagList[?Key=='$2'].Value | [0]" --output text; }

# A node is a parameter or a folder, never both: otherwise .../db and .../db/password can coexist
# and two readers disagree about which one is the credential.
refuse_node_clash() {
  local name=$1 prefix=$1 ancestors=() n
  while prefix=${prefix%/*}; [ "$prefix" != "$REALM" ] && [ -n "$prefix" ]; do ancestors+=("$prefix"); done
  if [ "${#ancestors[@]}" -gt 0 ]; then
    n=$(count_named "$(IFS=,; echo "${ancestors[*]}")")
    [ "$n" = 0 ] || die "$name: one of its parent folders is already a parameter."
  fi
  n=$(count_below "$name")
  [ "$n" = 0 ] || die "$name: parameters exist below it, so it is a folder."
}

put() {
  local name=${1:?name} description="" key_class=0 overwrite=0 new_key_version=0 exact=0 foreign=0 value n class version
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --description) description=${2:?--description needs a value}; shift 2 ;;
      --key-class) key_class=1; shift ;;
      --overwrite) overwrite=1; shift ;;
      --new-key-version) new_key_version=1; shift ;;
      --exact) exact=1; shift ;;
      --foreign) foreign=1; shift ;;
      *) die "put: unknown option $1" ;;
    esac
  done
  [ -n "$description" ] || die "put: --description is required: what it is, who issues it, how it rotates."
  [ -t 0 ] && die "put: the value comes on stdin, never as an argument."
  check_name "$name" "$foreign"
  IFS= read -r -d '' value || true
  [ "$exact" = 1 ] || value=${value%$'\n'}
  [ -n "$value" ] || die "put: the value on stdin is empty."

  local args=(--name "$name" --type SecureString --tier Advanced --key-id "$KEY_ALIAS"
    --description "$description" --value file:///dev/stdin)
  # Each AWS answer is assigned before it is compared: `[ "$(aws ...)" = 0 ]` discards the exit status,
  # so an AccessDenied would read as "absent" or "not a key".
  n=$(count_named "$name")
  if [ "$n" != 0 ]; then
    [ "$overwrite" = 1 ] || die "$name exists; --overwrite writes a new version."
    class=$(tag_value "$name" class)
    if [ "$class" = key ]; then
      [ "$new_key_version" = 1 ] || die "$name is a key: pin every consumer (remoteRef.version) first, then add
--new-key-version. The application's own rotation decides when the pins move."
    fi
    args+=(--overwrite)   # the API refuses tags on an overwrite; the ones set at creation stay
  else
    refuse_node_clash "$name"
    args+=(--tags Key=managed-by,Value=ssm.sh)
    [ "$key_class" = 1 ] && args+=(Key=class,Value=key)
  fi
  version=$(printf '%s' "$value" | aws_ssm put-parameter "${args[@]}" --query Version --output text)
  echo "$name: version $version"
}

list() {
  aws_ssm describe-parameters --parameter-filters "Key=Path,Option=Recursive,Values=${1%/}" \
    --query 'Parameters[].[Name,Version,Tier,Type,LastModifiedDate]' --output table
}

describe() {
  aws_ssm describe-parameters --parameter-filters "Key=Name,Option=Equals,Values=$1" --output table \
    --query 'Parameters[0].{Name:Name,Version:Version,Tier:Tier,Type:Type,Key:KeyId,Modified:LastModifiedDate,Description:Description}'
  aws_ssm list-tags-for-resource --resource-type Parameter --resource-id "$1" --query TagList --output table
  aws_ssm get-parameter-history --name "$1" --output table \
    --query 'Parameters[].{Version:Version,Modified:LastModifiedDate,Labels:join(`,`,Labels)}'
}

# Copies every parameter below one prefix to another with its description and key class, for an
# application that changes clusters. A key is copied, never regenerated: a restored database only
# opens under the key it was written with.
copy_tree() {
  local from=${1:?from}; local to=${2:?to} names name rel description flags n class
  from=${from%/}; to=${to%/}
  n=$(count_below "$to")
  [ "$n" = 0 ] || die "$to already holds parameters; copy-tree only fills an empty prefix."
  names=$(aws_ssm describe-parameters --parameter-filters "Key=Path,Option=Recursive,Values=$from" \
    --query 'Parameters[].Name' --output text)
  [ -n "$names" ] && [ "$names" != None ] || die "$from holds no parameters; nothing was copied."
  for name in $names; do
    [ "$name" = None ] && continue
    rel=${name#"$from"}
    check_name "$to$rel" 0
    description=$(aws_ssm describe-parameters --parameter-filters "Key=Name,Option=Equals,Values=$name" \
      --query 'Parameters[0].Description' --output text)
    flags=(--description "$description" --exact)
    class=$(tag_value "$name" class)
    [ "$class" = key ] && flags+=(--key-class)
    aws_ssm get-parameter --name "$name" --with-decryption --output json | jq -j .Parameter.Value | put "$to$rel" "${flags[@]}"
  done
}

case "${1:-}" in
  check) check_name "${2:?name}" "$([ "${3:-}" = --foreign ] && echo 1 || echo 0)"; echo "$2: ok" ;;
  put) shift; put "$@" ;;
  list) list "${2:?prefix}" ;;
  describe) describe "${2:?name}" ;;
  copy-tree) copy_tree "${2:-}" "${3:-}" ;;
  *) sed -n '2,16p' "$0" >&2; exit 2 ;;
esac
