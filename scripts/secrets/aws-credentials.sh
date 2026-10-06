#!/usr/bin/env bash
# Store the experiment's scoped AWS access key in private custody and in the lab as the Secret the
# static SecretStore reads. Values are read from files or the hidden prompt, never from arguments.
#   aws-credentials.sh import <region> <reader-role-arn>   (prompts for the key id and secret)
#   aws-credentials.sh apply                               (creates/updates Secret secret-lab-aws/aws-credentials)
#   aws-credentials.sh forget                              (deletes the Secret and the custody files)
#   aws-credentials.sh tenant a|b                          (Secret external-secrets/aws-credentials from tenant key a or b)
#   aws-credentials.sh tenant-remove                       (deletes that Secret)
# `tenant` stands in for the tenant bootstrap: a platform delivers that Secret to a tenant cluster,
# and nothing in the cluster's own GitOps tree may manage it.
set +x; set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
AWS_STATE="${SECRET_STATE_DIR}/aws"; mkdir -p "$AWS_STATE"; chmod 700 "$AWS_STATE"
case "${1:-}" in
  import)
    region="${2:?region}"; role_arn="${3:?reader role arn}"
    read -r -s -p 'AWS access key id (hidden): ' id; echo >&2
    read -r -s -p 'AWS secret access key (hidden): ' secret; echo >&2
    printf '%s' "$id" | private_write "${AWS_STATE}/access_key_id"
    printf '%s' "$secret" | private_write "${AWS_STATE}/secret_access_key"
    jq -n --arg r "$region" --arg a "$role_arn" '{region: $r, reader_role_arn: $a}' | private_write "${AWS_STATE}/config.json"
    echo 'Stored in private custody. Next: aws-credentials.sh apply, then vault.sh aws.' ;;
  apply)
    ensure_namespace secret-lab-aws
    k -n secret-lab-aws create secret generic aws-credentials \
      --from-file=aws_access_key_id="${AWS_STATE}/access_key_id" \
      --from-file=aws_secret_access_key="${AWS_STATE}/secret_access_key" \
      --dry-run=client -o yaml | k apply --server-side --field-manager=secret-bootstrap -f - >/dev/null
    echo 'Secret secret-lab-aws/aws-credentials applied.' ;;
  forget)
    k -n secret-lab-aws delete secret aws-credentials --ignore-not-found >/dev/null
    rm -f "${AWS_STATE}/access_key_id" "${AWS_STATE}/secret_access_key" "${AWS_STATE}/config.json"
    echo 'Static key removed from the cluster and from custody. Delete the IAM access key in AWS as well; this script cannot.' ;;
  tenant)
    slot="${2:-}"; [[ $slot == a || $slot == b ]] || { echo 'Usage: aws-credentials.sh tenant a|b' >&2; exit 2; }
    dir="${AWS_STATE}/tenant/${slot}"
    [ -s "${dir}/access_key_id" ] && [ -s "${dir}/secret_access_key" ] ||
      { echo "No tenant key ${slot} in custody; run experiments/aws/tenant-iam.sh apply first." >&2; exit 1; }
    k -n external-secrets create secret generic aws-credentials \
      --from-file=aws_access_key_id="${dir}/access_key_id" \
      --from-file=aws_secret_access_key="${dir}/secret_access_key" \
      --dry-run=client -o yaml | k apply --server-side --field-manager=tenant-bootstrap -f - >/dev/null
    echo "Secret external-secrets/aws-credentials holds tenant key ${slot}." ;;
  tenant-remove)
    k -n external-secrets delete secret aws-credentials --ignore-not-found >/dev/null
    echo 'Secret external-secrets/aws-credentials removed.' ;;
  *) echo 'Usage: aws-credentials.sh import <region> <reader-role-arn> | apply | forget | tenant a|b | tenant-remove' >&2; exit 2 ;;
esac
