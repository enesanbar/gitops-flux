#!/usr/bin/env bash
# Store the experiment's scoped AWS access key in private custody and in the lab as the Secret the
# static SecretStore reads. Values are read from files or the hidden prompt, never from arguments.
#   aws-credentials.sh import <region> <reader-role-arn>   (prompts for the key id and secret)
#   aws-credentials.sh apply                               (creates/updates Secret secret-lab-aws/aws-credentials)
#   aws-credentials.sh forget                              (deletes the Secret and the custody files)
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
  *) echo 'Usage: aws-credentials.sh import <region> <reader-role-arn> | apply | forget' >&2; exit 2 ;;
esac
