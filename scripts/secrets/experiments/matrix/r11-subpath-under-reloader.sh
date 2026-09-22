#!/usr/bin/env bash
# Does a reloader carry a rotated value into a subPath-mounted file the process reads at start?
# R15 measured the environment-variable consumer; this measures the file consumer in the same Secret.
source "$(dirname "$0")/lib.sh"
flen() { $K -n trellis exec deploy/$1 -c $2 -- sh -c 'wc -c < /etc/trellis/secrets/service-token' 2>/dev/null | tr -d ' '; }
echo "R11 subPath consumer under a reloader start=$(now)"
"$V" login >/dev/null
echo "before: mcp file=$(flen trellis-mcp mcp) bytes, api file=$(flen trellis-api api) bytes, mcp generation=$($K -n trellis get deploy trellis-mcp -o jsonpath='{.metadata.generation}')"
gen0=$($K -n trellis get deploy trellis-mcp -o jsonpath='{.metadata.generation}'); T0=$(date -u +%s)
# a length-distinguishable value, so the check cannot pass on the old one
openssl rand -base64 60 | tr -d '\n' | "$V" cli kv put -mount=secret-lab trellis/service-token TRELLIS_SERVICE_TOKEN=- | grep -E '^version'
echo "[wait began $(el)] Secret carries the longer token: $(waitfor 180 "klen trellis trellis-secrets TRELLIS_SERVICE_TOKEN" 108)"
echo "[wait began $(el)] reloader bumped mcp -> generation $(waitfor 180 "$K -n trellis get deploy trellis-mcp -o jsonpath='{.metadata.generation}'" $((gen0+1)))"
$K -n trellis rollout status deploy/trellis-mcp --timeout=240s >/dev/null 2>&1
echo "$(el) mcp subPath file now $(flen trellis-mcp mcp) bytes (80 = the rotated value reached the file through the restart)"
echo "$(el) api file now $(flen trellis-api api) bytes; ready=$(ready)"
echo "-- restore the original token from version 1"
T0=$(date -u +%s); "$V" cli kv rollback -mount=secret-lab -version=1 trellis/service-token | grep -E '^version'
echo "[wait began $(el)] Secret back: $(waitfor 180 "klen trellis trellis-secrets TRELLIS_SERVICE_TOKEN" 60)"
$K -n trellis rollout status deploy/trellis-mcp --timeout=240s >/dev/null 2>&1; $K -n trellis rollout status deploy/trellis-api --timeout=240s >/dev/null 2>&1
echo "$(el) files restored: mcp=$(flen trellis-mcp mcp) api=$(flen trellis-api api) ready=$(ready)"
echo "R11 end=$(now)"
