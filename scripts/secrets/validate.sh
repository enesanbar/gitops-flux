#!/usr/bin/env bash
set +x
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
for component in sealed-secrets external-secrets vault-secrets-operator vault secret-stores secret-example-sealed secret-example-eso secret-example-vso; do
  k -n flux-system wait "kustomization/${component}" --for=condition=Ready --timeout=180s
done
for mode in sealed eso vso; do
  ns="secret-lab-${mode}"
  k -n "$ns" rollout status deployment/consumer --timeout=120s
  value="$(k -n "$ns" get secret "${mode}-example" -o json | jq -er '.data.message | @base64d')"
  [[ -n "$value" ]]
  match=false
  for attempt in {1..60}; do
    consumed="$(k -n "$ns" exec deployment/consumer -- cat /secrets/message)"
    if [[ "$consumed" == "$value" ]]; then match=true; break; fi
    sleep 2
  done
  [[ "$match" == true ]] || { echo "${mode}: workload did not consume current Secret" >&2; exit 1; }
  owner="$(k -n "$ns" get secret "${mode}-example" -o json | jq -er '.metadata.ownerReferences[0].kind')"
  case "$mode:$owner" in sealed:SealedSecret|eso:ExternalSecret|vso:VaultStaticSecret) ;; *) echo "Unexpected owner: $mode:$owner" >&2; exit 1;; esac
  if [[ "$mode" != sealed ]]; then
    source_value="$("${SECRETS_SCRIPT_DIR}/vault.sh" cli kv get -field=message "secret-lab/${mode}/example")"
    [[ "$value" == "$source_value" ]]
  fi
  echo "PASS $mode: source -> owned Kubernetes Secret -> running workload (values withheld)"
done
"${SECRETS_SCRIPT_DIR}/vault.sh" cli token lookup -format=json | jq -e '.data.policies | (index("root") == null and index("secret-lab-operator") != null)' >/dev/null
curl --fail --silent --show-error --cacert "${SECRET_STATE_DIR}/vault/ca.crt" https://vault.kindcluster.dev/ui/ | python3 -c 'import sys; s=sys.stdin.read(); assert "<html" in s.lower()'
echo 'PASS Vault: non-root operator token and TLS-verified UI route'
python3 - <<'PY'
from pathlib import Path
import os
p=Path(os.environ['SECRET_STATE_DIR'])
for f in [p, *p.rglob('*')]:
    if f.is_symlink(): raise SystemExit('Symlink in custody directory')
    if f.stat().st_mode & 0o077: raise SystemExit('Private state has group/other permissions')
print('PASS custody: host-only directories/files have no group/other access')
PY
echo 'All readiness checks passed. Use recover-sealed.sh --simulate-key-loss for the destructive controller-key recovery exercise.'
