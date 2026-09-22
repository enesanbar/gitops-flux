#!/usr/bin/env bash
# AWS row: endpoint unreachable, produced by black-holing the SSM endpoint in the lab's CoreDNS (reversible).
source "$(dirname "$0")/lib.sh"; NS=secret-lab-aws; REGION=$(jq -r .region "$SECRET_STATE_DIR/aws/config.json")
echo "AWS unreachable start=$(now)"; $F suspend kustomization secret-lab-aws >/dev/null
$K -n kube-system get configmap coredns -o json > /tmp/coredns.json; python3 - "$REGION" <<'PY'
import json,sys
cm=json.load(open("/tmp/coredns.json")); cf=cm["data"]["Corefile"]; host=f"ssm.{sys.argv[1]}.amazonaws.com"
if host not in cf:
    cf=cf.replace("    forward . /etc/resolv.conf", f"    hosts {{\n       127.0.0.1 {host}\n       fallthrough\n    }}\n    forward . /etc/resolv.conf",1)
cm["data"]["Corefile"]=cf; json.dump(cm,open("/tmp/coredns.patched.json","w"))
PY
$K apply -f /tmp/coredns.patched.json >/dev/null && $K -n kube-system rollout restart deploy/coredns >/dev/null && $K -n kube-system rollout status deploy/coredns --timeout=90s >/dev/null && echo "$(el) CoreDNS resolves the SSM endpoint to 127.0.0.1"
T0=$(date -u +%s); $K -n $NS annotate externalsecret llm-key-only force-sync="$(date +%s%N)" --overwrite >/dev/null
for i in $(seq 1 24); do st=$($K -n $NS get externalsecret llm-key-only -o jsonpath='{.status.conditions[0].reason}'); [ "$st" != "SecretSynced" ] && break; sleep 5; done
echo "$(el) llm-key-only=$st msg=$($K -n $NS get externalsecret llm-key-only -o jsonpath='{.status.conditions[0].message}' | cut -c1-120) store=$($K -n $NS get secretstore aws-static -o jsonpath='{.status.conditions[0].reason}') Secret kept=$($K -n $NS get secret llm-key-only -o go-template='{{len (index .data "TRELLIS_LLM_API_KEY")}}')"
echo "   event: $($K -n $NS get events --field-selector involvedObject.name=llm-key-only -o jsonpath='{range .items[*]}{.lastTimestamp} {.message}{"\n"}{end}' | tail -1 | grep -oE 'dial tcp[^,]*|connection refused|no such host|context deadline exceeded|i/o timeout' | head -1)"
# restore on the LIVE object: re-applying the saved copy conflicts on resourceVersion (measured)
$K -n kube-system get configmap coredns -o json | python3 -c 'import json,sys,re; cm=json.load(sys.stdin); cm["data"]["Corefile"]=re.sub(r"    hosts \{\n       127\.0\.0\.1 ssm\.[a-z0-9-]+\.amazonaws\.com\n       fallthrough\n    \}\n","",cm["data"]["Corefile"]); [cm["metadata"].pop(k,None) for k in ("resourceVersion","managedFields")]; json.dump(cm,sys.stdout)' | $K replace -f - >/dev/null; $K -n kube-system rollout restart deploy/coredns >/dev/null; $K -n kube-system rollout status deploy/coredns --timeout=90s >/dev/null; rm -f /tmp/coredns.json /tmp/coredns.patched.json
T0=$(date -u +%s); $K -n $NS annotate externalsecret llm-key-only force-sync="$(date +%s%N)" --overwrite >/dev/null; echo "$(el) after DNS restored: llm-key-only=$(waitfor 120 "$K -n $NS get externalsecret llm-key-only -o jsonpath='{.status.conditions[0].reason}'" SecretSynced)"
$F resume kustomization secret-lab-aws --timeout 2m >/dev/null 2>&1; echo "AWS unreachable end=$(now)"
