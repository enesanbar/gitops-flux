#!/usr/bin/env bash
# R14: add a brand-new secret the way a developer would under GitOps, counting steps and wall time.
# The new secret is real and stays: TRELLIS_EMBEDDING_API_KEY, an optional key the chart already reads.
source "$(dirname "$0")/lib.sh"; cd "$W"; echo "R14 developer friction (Vault half) start=$(now)"; T0=$(date -u +%s); "$V" login >/dev/null
echo "step 1 (operator/dev): write the value to the backend"; openssl rand -base64 32 | tr -d '\n' | "$V" cli kv put -mount=secret-lab trellis/embedding TRELLIS_EMBEDDING_API_KEY=- | grep -E '^version' | sed 's/^/   /'; echo "   $(el)"
echo "step 2 (dev): add three lines to the ExternalSecret in git"; python3 - <<'PY'
import pathlib, sys
p = pathlib.Path("components/trellis-secrets/external-secrets.yaml"); t = p.read_text()
if "TRELLIS_EMBEDDING_API_KEY" in t:
    print("   already present, leaving the file alone"); sys.exit(0)
old = "  - secretKey: TRELLIS_LLM_API_KEY\n    remoteRef:\n      key: trellis/llm\n      property: TRELLIS_LLM_API_KEY\n"
assert t.count(old) == 1
p.write_text(t.replace(old, old + "  - secretKey: TRELLIS_EMBEDDING_API_KEY\n    remoteRef:\n      key: trellis/embedding\n      property: TRELLIS_EMBEDDING_API_KEY\n"))
PY
kubectl kustomize components/trellis-secrets >/dev/null && echo "   render ok $(el)"
echo "step 3 (dev): commit and push — NOT done by this script. A measurement must not write shared"
echo "   history: it would race other agents and it is idempotent only by crashing. The diff is:"
git --no-pager diff --stat components/trellis-secrets/external-secrets.yaml | sed 's/^/   /'
echo "   Commit it yourself, then re-run from step 4. $(el)"
echo "step 4 (nobody, or an impatient dev): wait for Flux (source 1m + Kustomization 10m) or reconcile by hand"; $F reconcile kustomization trellis-secrets --with-source --timeout 3m 2>&1 | tail -1 | sed 's/^/   /'; echo "   $(el)"
echo "step 5: the Secret carries the key -> $(waitfor 120 "klen trellis trellis-secrets TRELLIS_EMBEDDING_API_KEY" 60) b64 chars $(el)"
echo "step 6 (dev): the process sees it only after a restart (env, optional secretKeyRef): before=$($K -n trellis exec deploy/trellis-api -c api -- sh -c 'echo ${#TRELLIS_EMBEDDING_API_KEY}' 2>/dev/null)"; $K -n trellis rollout restart deploy/trellis-api >/dev/null; $K -n trellis rollout status deploy/trellis-api --timeout=240s >/dev/null 2>&1; echo "   after restart=$($K -n trellis exec deploy/trellis-api -c api -- sh -c 'echo ${#TRELLIS_EMBEDDING_API_KEY}' 2>/dev/null) $(el) ready=$(ready)"
echo "ROTATION friction: step A kv put new version; step B wait <= refreshInterval (1m) or force-sync; step C restart (or Reloader)"; # The new value must differ in LENGTH from the old one, or the wait is satisfied by the old value.
T0=$(date -u +%s); openssl rand -base64 60 | tr -d '\n' | "$V" cli kv put -mount=secret-lab trellis/embedding TRELLIS_EMBEDDING_API_KEY=- | grep -E '^version' | sed 's/^/   /'
echo "   [wait began $(el)] Secret carries the longer value: $(waitfor 180 "klen trellis trellis-secrets TRELLIS_EMBEDDING_API_KEY" 108) (natural 1m interval, no force)"
echo "R14 end=$(now); steps to add: 6 (1 backend write, 1 YAML edit, 1 commit+push, 1 wait/reconcile, 1 verify, 1 restart); steps to rotate: 3 (write, wait, restart)"
