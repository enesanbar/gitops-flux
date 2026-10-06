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
#     an AWS error part-way through leaves the parameters already written at <to-prefix>; delete
#     them before retrying. A copy carries every superseded value too, including one that was
#     rotated out because it leaked.
#
#   openssl rand -base64 32 | ssm.sh put /devops/dev-cluster/<app>/encryption_key --key-class \
#     --description "Encryption key; generated here; rotates only through the application's re-wrap"
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
LEAF='^[a-z][a-z0-9_]*$'                     # snake_case: usable unchanged as a secretKey and a template variable

die() { echo "$*" >&2; exit 1; }

split_path() {
  local path=$1
  [[ $path == *$'\n'* ]] && die "$path: a name has one line."
  [[ $path == */ ]] && die "$path: a trailing slash names a folder, not a parameter."
  IFS=/ read -r -a parts <<<"$path"
}

check_name() {
  local name=$1 foreign=$2 part parts
  case "$name" in
    "$FOREIGN"/*)
      [ "$foreign" = 1 ] || die "$name: ${FOREIGN}/ belongs to another team; it is written only with --foreign."
      [[ ${name#"$FOREIGN"/} =~ $LEAF ]] || die "$name: that realm is flat, ${FOREIGN}/<snake_case_name>."
      return ;;
    "$REALM"/*) ;;
    *) die "$name: outside ${REALM}/." ;;
  esac
  split_path "${name#"$REALM"/}"
  [ "${#parts[@]}" -ge 3 ] || die "$name: needs ${REALM}/<cluster>/<namespace>/<name> at least."
  [ "$(( ${#parts[@]} + 1 ))" -le 15 ] || die "$name: Parameter Store allows 15 levels at most."
  for part in "${parts[@]:0:${#parts[@]}-1}"; do
    [[ $part =~ $SEGMENT ]] && [ "${#part}" -le 63 ] ||
      die "$name: '$part' must be a lowercase Kubernetes-style name (letters, digits, '-')."
  done
  [[ ${parts[${#parts[@]}-1]} =~ $LEAF ]] || die "$name: '${parts[${#parts[@]}-1]}' must be snake_case."
}

# A prefix copy-tree reads or fills: a namespace at least, so a typo cannot take a whole cluster.
check_prefix() {
  local prefix=$1 part parts
  [[ $prefix == "$REALM"/* ]] || die "$prefix: outside ${REALM}/."
  split_path "${prefix#"$REALM"/}"
  [ "${#parts[@]}" -ge 2 ] || die "$prefix: copy-tree works on ${REALM}/<cluster>/<namespace> or below."
  for part in "${parts[@]}"; do [[ $part =~ $SEGMENT ]] || die "$prefix: '$part' is not a folder name."; done
}

# The CLI's history records every request and response, so with it on a put, and copy-tree's
# decrypted reads, would leave the values in ~/.aws/cli/history. aws_ssm unsets the profile, so the
# default profile's setting is the one that applies.
refuse_cli_history() {
  local history
  history=$( unset AWS_PROFILE AWS_DEFAULT_PROFILE; aws configure get cli_history 2>/dev/null || true )
  [ "$history" != enabled ] || die "cli_history is enabled in the AWS CLI's default profile; turn it off before this reads or writes values."
}

# The lab writes with the experiment user's key from custody; the credentials reach the CLI through
# its environment, never its arguments.
aws_ssm() {
  (
    unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_SESSION_TOKEN
    AWS_ACCESS_KEY_ID="$(cat "${AWS_STATE}/access_key_id")"
    AWS_SECRET_ACCESS_KEY="$(cat "${AWS_STATE}/secret_access_key")"
    AWS_REGION="$(jq -r .region "${AWS_STATE}/config.json")"
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION
    aws ssm "$@"
  )
}

# JSON, never text: the CLI applies --query to each page of text output, and DescribeParameters may
# return empty pages, so a text answer can read "0" and "1" at once.
count_named() { aws_ssm describe-parameters --parameter-filters "Key=Name,Option=Equals,Values=$1" --output json | jq '.Parameters | length'; }
count_below() { aws_ssm describe-parameters --parameter-filters "Key=Path,Option=Recursive,Values=${1%/}" --output json | jq '.Parameters | length'; }
tag_value() { aws_ssm list-tags-for-resource --resource-type Parameter --resource-id "$1" --output json | jq -r --arg k "$2" '[.TagList[] | select(.Key == $k) | .Value][0] // ""'; }

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
  local name=${1:?name} description="" key_class=0 overwrite=0 new_key_version=0 exact=0 foreign=0 value n owner class version
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
    owner=$(tag_value "$name" managed-by)
    [ "$owner" = ssm.sh ] || die "$name was not written by ssm.sh (managed-by: ${owner:-none}); refusing to take it over."
    class=$(tag_value "$name" class)
    if [ "$class" = key ] || [ "$key_class" = 1 ]; then
      [ "$new_key_version" = 1 ] || die "$name is a key: pin every consumer (remoteRef.version) first, then add
--new-key-version. The application's own rotation decides when the pins move."
      # The API refuses tags on an overwrite, so a key class asked for now is tagged beside it.
      [ "$class" = key ] || aws_ssm add-tags-to-resource --resource-type Parameter --resource-id "$name" --tags Key=class,Value=key
    fi
    args+=(--overwrite)
  else
    refuse_node_clash "$name"
    args+=(--tags Key=managed-by,Value=ssm.sh)
    [ "$key_class" = 1 ] && args+=(Key=class,Value=key)
  fi
  version=$(printf '%s' "$value" | aws_ssm put-parameter "${args[@]}" --query Version --output text)
  echo "$name: version $version"
}

list() {
  aws_ssm describe-parameters --parameter-filters "Key=Path,Option=Recursive,Values=${1%/}" --output json |
    jq -r '.Parameters[] | [.Name, .Version, .Tier, .Type, .LastModifiedDate] | @tsv'
}

describe() {
  aws_ssm describe-parameters --parameter-filters "Key=Name,Option=Equals,Values=$1" --output json |
    jq '.Parameters[0] | {Name, Version, Tier, Type, KeyId, LastModifiedDate, Description}'
  aws_ssm list-tags-for-resource --resource-type Parameter --resource-id "$1" --output json | jq -c '.TagList'
  aws_ssm get-parameter-history --name "$1" --output json |
    jq -r '.Parameters[] | [.Version, .LastModifiedDate, ((.Labels // []) | join(","))] | @tsv'
}

# Parameter Store keeps the last 100 versions; a history that is no longer 1..N cannot be replayed
# with the numbers a pin names. The third argument says what the refusal left behind.
refuse_version_gap() {
  local name=$1 versions=$2 trailing=$3 count
  count=$(printf '%s' "$versions" | jq length)
  printf '%s' "$versions" | jq -e --argjson count "$count" 'sort == [range(1; $count + 1)]' >/dev/null ||
    die "$name: its versions are not 1..$count, so a copy could not keep the numbers its pins name. $trailing"
}

# Copies every parameter below one prefix to another for an application that changes clusters,
# replaying each one's whole version history in order: a pin names a version NUMBER, so a copy that
# kept only the latest value as version 1 would hand a pinned consumer different bytes. A key is
# copied, never regenerated: a restored database only opens under the key it was written with.
copy_tree() {
  local from=${1:?from}; local to=${2:?to} names name rel history versions count i class n flags=() labels ltext
  from=${from%/}; to=${to%/}
  check_prefix "$from"; check_prefix "$to"
  [ "$from" != "$to" ] || die "copy-tree: the prefixes are the same."
  n=$(count_below "$to")
  [ "$n" = 0 ] || die "$to already holds parameters; copy-tree only fills an empty prefix."
  names=$(aws_ssm describe-parameters --parameter-filters "Key=Path,Option=Recursive,Values=$from" --output json | jq -r '.Parameters[].Name')
  [ -n "$names" ] || die "$from holds no parameters; nothing was copied."
  # Every history is validated, undecrypted, before anything is written: a gap discovered in one
  # parameter must never leave an earlier, valid parameter already copied for a retry to trip over.
  for name in $names; do
    check_name "$to${name#"$from"}" 0
    versions=$(aws_ssm get-parameter-history --name "$name" --output json | jq -c '[.Parameters[].Version]')
    refuse_version_gap "$name" "$versions" "Nothing was copied."
  done
  for name in $names; do
    rel=${name#"$from"}
    history=$(aws_ssm get-parameter-history --name "$name" --with-decryption --output json | jq -c '.Parameters | sort_by(.Version)')
    versions=$(printf '%s' "$history" | jq -c '[.[].Version]')
    refuse_version_gap "$name" "$versions" "Nothing more was copied."
    count=$(printf '%s' "$history" | jq length)
    class=$(tag_value "$name" class)
    for ((i = 0; i < count; i++)); do
      flags=(--exact --description "$(printf '%s' "$history" | jq -r --argjson i "$i" --arg n "$name" '.[$i].Description // ("Copied from " + $n)')")
      if [ "$i" = 0 ]; then [ "$class" = key ] && flags+=(--key-class)
      else flags+=(--overwrite); [ "$class" = key ] && flags+=(--new-key-version); fi
      printf '%s' "$history" | jq -j --argjson i "$i" '.[$i].Value' | put "$to$rel" "${flags[@]}" >/dev/null
      # A label is what keeps Parameter Store from dropping the version a pin names as older
      # versions age out past 100, so that protection survives the copy only if the label lands
      # on the same version number at the destination.
      ltext=$(printf '%s' "$history" | jq -r --argjson i "$i" '(.[$i].Labels // []) | join(" ")')
      read -r -a labels <<<"$ltext"
      if [ "${#labels[@]}" -gt 0 ]; then
        aws_ssm label-parameter-version --name "$to$rel" --parameter-version "$((i + 1))" --labels "${labels[@]}" >/dev/null
      fi
    done
    echo "$to$rel: versions 1-$count copied"
  done
}

case "${1:-}" in
  check) check_name "${2:?name}" "$([ "${3:-}" = --foreign ] && echo 1 || echo 0)"; echo "$2: ok" ;;
  put) shift; refuse_cli_history; put "$@" ;;
  list) refuse_cli_history; list "${2:?prefix}" ;;
  describe) refuse_cli_history; describe "${2:?name}" ;;
  copy-tree) refuse_cli_history; copy_tree "${2:-}" "${3:-}" ;;
  *) sed -n '2,19p' "$0" >&2; exit 2 ;;
esac
