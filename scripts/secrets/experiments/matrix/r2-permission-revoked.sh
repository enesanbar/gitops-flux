#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; P="$W/scripts/secrets/vault/policies/trellis.hcl"
echo "R2 permission revoked start=$(now)"; cp "$P" "$P.bak"
sed -i '' 's#^path "secret-lab/data/trellis/\*" { capabilities = \["read"\] }#\# read path removed for the experiment#' "$P"; grep -c 'read path removed' "$P" | sed 's/^/policy edited (marker count): /'
"$V" bootstrap >/dev/null && echo "$(now) bootstrap applied the narrowed policy"; T0=$(date -u +%s); sync trellis trellis-secrets
echo "[wait began $(el)] trellis-secrets -> $(waitfor 300 'es trellis trellis-secrets' SecretSyncedError) msg=$(esmsg trellis trellis-secrets)"
echo "$(el) store=$(store) (store validation caches the login; note whether it notices)"; echo "$(el) Secret retained: TRELLIS_LLM_API_KEY=$(klen trellis trellis-secrets TRELLIS_LLM_API_KEY) ready=$(ready)"
mv "$P.bak" "$P"; "$V" bootstrap >/dev/null && echo "$(now) policy restored"; T0=$(date -u +%s); sync trellis trellis-secrets
echo "[wait began $(el)] trellis-secrets -> $(waitfor 300 'es trellis trellis-secrets' SecretSynced)"; cd "$W" && git status --short scripts/secrets/vault/policies | sed 's/^/git: /'; echo "R2 end=$(now)"
