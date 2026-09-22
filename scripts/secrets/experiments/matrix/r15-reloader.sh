#!/usr/bin/env bash
# R15: restart tooling with evidence. Reloader restarts the annotated Deployments when the Secret they
# consume changes; measured from the Vault write to the process reporting the new value.
source "$(dirname "$0")/lib.sh"; echo "R15 Reloader start=$(now)"; "$V" login >/dev/null
$K -n trellis annotate deploy trellis-api trellis-worker trellis-mcp reloader.stakater.com/auto=true --overwrite >/dev/null; echo "annotated api, worker, mcp with reloader.stakater.com/auto=true"
before=$($K -n trellis exec deploy/trellis-api -c api -- sh -c 'echo ${#TRELLIS_LLM_API_KEY}' 2>/dev/null); gen0=$($K -n trellis get deploy trellis-api -o jsonpath='{.metadata.generation}')
echo "before: process llm-key len=$before api generation=$gen0"; T0=$(date -u +%s)
openssl rand -base64 27 | tr -d '\n' | "$V" cli kv put -mount=secret-lab trellis/llm TRELLIS_LLM_API_KEY=- | grep -E '^version' | sed 's/^/   /'
echo "[wait began $(el)] Secret updated -> $(waitfor 120 "klen trellis trellis-secrets TRELLIS_LLM_API_KEY" 48) b64 chars"
echo "[wait began $(el)] Reloader bumped the api Deployment -> generation $(waitfor 120 "$K -n trellis get deploy trellis-api -o jsonpath='{.metadata.generation}'" $((gen0+1)))"
$K -n trellis rollout status deploy/trellis-api --timeout=240s >/dev/null 2>&1; echo "$(el) api rolled out; process llm-key len now=$($K -n trellis exec deploy/trellis-api -c api -- sh -c 'echo ${#TRELLIS_LLM_API_KEY}' 2>/dev/null) ready=$(ready)"
$K -n trellis rollout status deploy/trellis-worker --timeout=240s >/dev/null 2>&1; $K -n trellis rollout status deploy/trellis-mcp --timeout=240s >/dev/null 2>&1; echo "$(el) worker and mcp rolled out too (mcp restarted although it does not read the llm key: Reloader restarts on any change of a referenced Secret)"
echo "-- Reloader's own trace on the Deployment:"; $K -n trellis get deploy trellis-api -o jsonpath='{range $k, $v := .spec.template.metadata.annotations}{$k}{"\n"}{end}' | grep -i reloader | sed 's/^/   annotation key: /'; $K -n reloader logs deploy/reloader-reloader --since=5m 2>/dev/null | grep -ciE 'trellis' | sed 's/^/   reloader log lines mentioning trellis: /'
echo "-- rollback the value (this triggers a second restart, the cost of the tool)"; T0=$(date -u +%s); "$V" cli kv rollback -mount=secret-lab -version=1 trellis/llm | grep -E '^version' | sed 's/^/   /'; gen1=$($K -n trellis get deploy trellis-api -o jsonpath='{.metadata.generation}')
echo "[wait began $(el)] rollback bumped the Deployment again -> generation $(waitfor 180 "$K -n trellis get deploy trellis-api -o jsonpath='{.metadata.generation}'" $((gen1+1)))"
$K -n trellis rollout status deploy/trellis-api --timeout=240s >/dev/null 2>&1; echo "$(el) after rollback: process llm-key len=$($K -n trellis exec deploy/trellis-api -c api -- sh -c 'echo ${#TRELLIS_LLM_API_KEY}' 2>/dev/null) ready=$(ready)"
echo "R15 end=$(now) (annotations left in place for GW.6's judgement; remove with kubectl annotate ... reloader.stakater.com/auto-)"
