#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
echo "R5/R8 generated Secret deleted + restarts start=$(now)"; echo "api pods before:"; pods api | sed 's/^/   /'
T0=$(date -u +%s); $K -n trellis delete secret trellis-secrets >/dev/null; echo "$(el) Secret deleted; immediately rollout restart trellis-api"; $K -n trellis rollout restart deploy/trellis-api >/dev/null
echo "$(el) Secret recreated by ESO -> $(waitfor 120 "klen trellis trellis-secrets TRELLIS_KEK" 60) b64 chars (KEK)"; sleep 3; echo "$(el) api pods during the rollout:"; pods api | sed 's/^/   /'
$K -n trellis rollout status deploy/trellis-api --timeout=240s >/dev/null 2>&1 && echo "$(el) api rollout complete, ready=$(ready)" || echo "$(el) api rollout NOT complete"
echo "-- running mcp pods (not restarted) still have their mounted file? bytes=$($K -n trellis exec deploy/trellis-mcp -c mcp -- sh -c 'wc -c < /etc/trellis/secrets/service-token' 2>/dev/null | tr -d ' ')"
echo "R7 ESO restart during a rotation start=$(now)"; "$V" login >/dev/null; before=$(klen trellis trellis-secrets TRELLIS_LLM_API_KEY)
T0=$(date -u +%s); openssl rand -base64 30 | tr -d '\n' | "$V" cli kv put -mount=secret-lab trellis/llm TRELLIS_LLM_API_KEY=- | grep -E '^version'; $K -n external-secrets rollout restart deploy/external-secrets >/dev/null; echo "$(el) ESO controller restarting"
for i in $(seq 1 40); do l=$(klen trellis trellis-secrets TRELLIS_LLM_API_KEY); [ "$l" != "$before" ] && { echo "$(el) Secret updated after the ESO restart (b64len $before -> $l)"; break; }; sleep 5; done
echo "$(el) ESO pods:"; $K -n external-secrets get pods -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[0].ready' --no-headers | sed 's/^/   /'
"$V" cli kv rollback -mount=secret-lab -version=1 trellis/llm | grep -E '^version'; sync trellis trellis-secrets; echo "$(el) rolled back -> LLM b64len $(waitfor 120 "klen trellis trellis-secrets TRELLIS_LLM_API_KEY" 220)"
echo "-- R8 application restart: api+worker rollout, time to Ready, current Secret mounted"; T0=$(date -u +%s); $K -n trellis rollout restart deploy/trellis-api deploy/trellis-worker >/dev/null; $K -n trellis rollout status deploy/trellis-api --timeout=240s >/dev/null 2>&1; $K -n trellis rollout status deploy/trellis-worker --timeout=240s >/dev/null 2>&1; echo "$(el) both rolled out; api llm-key len in process: $($K -n trellis exec deploy/trellis-api -c api -- sh -c 'echo ${#TRELLIS_LLM_API_KEY}' 2>/dev/null) ready=$(ready)"
echo "R5/R7/R8 end=$(now)"
