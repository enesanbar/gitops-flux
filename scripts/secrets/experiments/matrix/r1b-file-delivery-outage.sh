#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; echo "R1b file-delivery restart during a backend outage start=$(now)"
echo "before: store=$(store) es=$(es trellis trellis-secrets) ready=$(ready) api-kek-command=$($K -n trellis exec deploy/trellis-api -c api -- sh -c 'echo ${TRELLIS_KEK_COMMAND:-unset}' 2>/dev/null)"
T0=$(date -u +%s); $K -n vault delete pod vault-0 --wait=false >/dev/null; sleep 25
echo "[wait began $(el)] vault-0 sealed=$($K -n vault exec vault-0 -c vault -- vault status -format=json 2>/dev/null | jq -r .sealed) store=$(waitfor 200 'store' InvalidProviderConfig)"
echo "-- rollout restart trellis-api and trellis-worker while Vault is sealed (file delivery from the mounted Secret)"
$K -n trellis rollout restart deploy/trellis-api deploy/trellis-worker >/dev/null
$K -n trellis rollout status deploy/trellis-api --timeout=240s >/dev/null 2>&1 && echo "$(el) api rollout COMPLETE during the outage" || echo "$(el) api rollout did NOT complete"
$K -n trellis rollout status deploy/trellis-worker --timeout=240s >/dev/null 2>&1 && echo "$(el) worker rollout COMPLETE during the outage" || echo "$(el) worker rollout did NOT complete"
echo "$(el) ready=$(ready) api pods:"; pods api | sed 's/^/   /'
echo "$(el) es=$(es trellis trellis-secrets) (stale but present) Secret KEK=$(klen trellis trellis-secrets TRELLIS_KEK)"
echo "-- unseal at $(now)"; T0=$(date -u +%s); "$V" unseal | tail -1; echo "[wait began $(el)] store -> $(waitfor 400 'store' Valid)"; echo "$(el) trellis-secrets -> $(waitfor 400 'es trellis trellis-secrets' SecretSynced)"; echo "R1b end=$(now)"
