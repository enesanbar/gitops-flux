#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; S8="$W/scripts/secrets/experiments/kek-command/values-overlay.yaml"
: "${S5:?S5 = the release values file}" "${CH:?CH = the trellis chart directory}"; H="helm --kube-context kind-local-dind-cluster"
echo "R1 backend unavailable start=$(now)"; echo "before: store=$(store) es=$(es trellis trellis-secrets) ready=$(ready)"
echo "-- switch Trellis to the KEK_COMMAND shape first (so a worker restart during the outage needs Vault)"
$H upgrade trellis $CH -n trellis -f $S5 -f $S8 --wait --timeout 5m >/dev/null 2>&1 && echo "$(el) helm: KEK_COMMAND values deployed" || echo "$(el) helm upgrade FAILED"
echo "-- delete pod vault-0 (documented restart: Vault comes back sealed) at $(now)"; T0=$(date -u +%s)
$K -n vault delete pod vault-0 --wait=false >/dev/null
echo "$(el) vault-0 pod running again: $(waitfor 120 "$K -n vault get pod vault-0 -o jsonpath='{.status.phase}'" Running) sealed=$($K -n vault exec vault-0 -c vault -- vault status -format=json 2>/dev/null | jq -r .sealed)"
echo "$(el) store -> $(waitfor 400 'store' InvalidProviderConfig)"; echo "$(el) trellis-secrets -> $(waitfor 400 'es trellis trellis-secrets' SecretSyncedError) msg=$(esmsg trellis trellis-secrets)"
echo "$(el) Secret still there: TRELLIS_KEK=$(klen trellis trellis-secrets TRELLIS_KEK) ; Trellis ready=$(ready)"
echo "-- rollout restart trellis-api during the outage (file delivery: must start from the mounted Secret)"
$K -n trellis rollout restart deploy/trellis-api >/dev/null; $K -n trellis rollout status deploy/trellis-api --timeout=180s >/dev/null 2>&1 && echo "$(el) api restarted fine during the outage, ready=$(ready)" || echo "$(el) api restart did NOT complete"
echo "-- rollout restart trellis-worker during the outage (KEK_COMMAND: must refuse to start)"
$K -n trellis rollout restart deploy/trellis-worker >/dev/null; sleep 45; echo "$(el) worker pods:"; pods worker | sed 's/^/   /'
P=$($K -n trellis get pods -l app.kubernetes.io/component=worker --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}'); echo "   newest worker log tail: $($K -n trellis logs "$P" -c worker --previous 2>/dev/null | tail -2 | tr '\n' '|' | cut -c1-200)"
echo "-- unseal at $(now)"; T0=$(date -u +%s); "$V" unseal | tail -1
echo "$(el) store -> $(waitfor 600 'store' Valid)"; echo "$(el) trellis-secrets -> $(waitfor 600 'es trellis trellis-secrets' SecretSynced)"
echo "$(el) worker recovered -> $(waitfor 400 "$K -n trellis get deploy trellis-worker -o jsonpath='{.status.readyReplicas}'" 2) ready replicas"
echo "-- revert Trellis to file delivery"; $H upgrade trellis $CH -n trellis -f $S5 --wait --timeout 5m >/dev/null 2>&1 && echo "$(el) reverted, ready=$(ready)" || echo "$(el) revert FAILED"
"$V" login >/dev/null; "$W/scripts/secrets/validate.sh" 2>&1 | grep -cE '^PASS' | sed 's/^/validate.sh PASS lines: /'
echo "R1 end=$(now)"
