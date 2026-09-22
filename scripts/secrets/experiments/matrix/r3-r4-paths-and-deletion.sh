#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
echo "R3 one bad entry start=$(now)"; $F suspend kustomization trellis-secrets >/dev/null
$K -n trellis patch externalsecret trellis-secrets --type json -p '[{"op":"replace","path":"/spec/data/2/remoteRef/property","value":"NOPE"}]' >/dev/null; T0=$(date -u +%s); sync trellis trellis-secrets
echo "$(el) -> $(waitfor 120 'es trellis trellis-secrets' SecretSyncedError) msg=$(esmsg trellis trellis-secrets)"
echo "$(el) Secret intact: KEK=$(klen trellis trellis-secrets TRELLIS_KEK) TOKEN=$(klen trellis trellis-secrets TRELLIS_SERVICE_TOKEN) LLM=$(klen trellis trellis-secrets TRELLIS_LLM_API_KEY) (one bad entry blocks the refresh of all three, nothing is removed)"
$K -n trellis patch externalsecret trellis-secrets --type json -p '[{"op":"replace","path":"/spec/data/2/remoteRef/property","value":"TRELLIS_LLM_API_KEY"}]' >/dev/null; sync trellis trellis-secrets; echo "$(el) restored -> $(waitfor 120 'es trellis trellis-secrets' SecretSynced)"
$F resume kustomization trellis-secrets --timeout 2m >/dev/null 2>&1; echo "R3 end=$(now)"
echo "R4 source value deleted start=$(now)"; "$V" login >/dev/null
"$V" cli kv delete -mount=secret-lab trellis/llm | tail -1; T0=$(date -u +%s); sync trellis trellis-secrets
echo "$(el) trellis-secrets -> $(waitfor 120 'es trellis trellis-secrets' SecretSyncedError) msg=$(esmsg trellis trellis-secrets)"; echo "$(el) Retain: LLM key still $(klen trellis trellis-secrets TRELLIS_LLM_API_KEY) b64 chars; ready=$(ready)"
"$V" cli kv undelete -mount=secret-lab -versions=3 trellis/llm | tail -1; sync trellis trellis-secrets; echo "$(el) undeleted -> $(waitfor 120 'es trellis trellis-secrets' SecretSynced)"
echo "-- contrast on the copies: copy-b to deletionPolicy Delete, then delete the latest platform/wildcard version"; $F suspend kustomization secret-lab-pki >/dev/null
$K -n secret-lab-pki patch externalsecret wildcard-copy-b --type merge -p '{"spec":{"target":{"deletionPolicy":"Delete"}}}' >/dev/null
ver=$("$V" cli kv metadata get -mount=secret-lab -format=json platform/wildcard | jq -r .data.current_version); "$V" cli kv delete -mount=secret-lab platform/wildcard | tail -1; T0=$(date -u +%s); sync secret-lab-pki wildcard-copy-a; sync secret-lab-pki wildcard-copy-b; sleep 20
echo "$(el) copy-a (Retain): es=$(es secret-lab-pki wildcard-copy-a) secret tls.crt=$(klen secret-lab-pki wildcard-copy-a tls.crt)"; echo "$(el) copy-b (Delete): es=$(es secret-lab-pki wildcard-copy-b) secret tls.crt=$(klen secret-lab-pki wildcard-copy-b tls.crt)"
"$V" cli kv undelete -mount=secret-lab -versions="$ver" platform/wildcard | tail -1; sync secret-lab-pki wildcard-copy-a; sync secret-lab-pki wildcard-copy-b; sleep 20; echo "$(el) after undelete: copy-a=$(es secret-lab-pki wildcard-copy-a)/$(klen secret-lab-pki wildcard-copy-a tls.crt) copy-b=$(es secret-lab-pki wildcard-copy-b)/$(klen secret-lab-pki wildcard-copy-b tls.crt)"
$K -n secret-lab-pki patch externalsecret wildcard-copy-b --type merge -p '{"spec":{"target":{"deletionPolicy":"Retain"}}}' >/dev/null; $F resume kustomization secret-lab-pki --timeout 2m >/dev/null 2>&1; echo "R4 end=$(now)"
