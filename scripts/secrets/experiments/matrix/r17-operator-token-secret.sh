#!/usr/bin/env bash
# R17: can the operator obtain a token for a ServiceAccount no Role names, with its token-request grant
# already removed? It writes Secrets wherever it delivers, and a kubernetes.io/service-account-token
# Secret is filled in by the cluster's token controller, so the question is whether that door is open.
# Acts only in a scratch namespace on a scratch ServiceAccount that has no bindings, as the operator's
# identity through impersonation, prints the token's length and never its value, and deletes the
# namespace on exit.
. "$(dirname "$0")/lib.sh"
NS=secret-lab-tokenprobe
AS=--as=system:serviceaccount:external-secrets:external-secrets
cleanup() { $K delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1; }
trap cleanup EXIT
can() { local out; out=$($K auth can-i "$@" $AS 2>/dev/null); case "$out" in yes|no) echo "$out" ;; *) echo ERR ;; esac; }
echo "=== R17 operator token via a service-account-token Secret, $(now) ==="
echo "   token request for a ServiceAccount no Role names: $(can create serviceaccounts --subresource=token -n kube-system)"
echo "   create Secrets in kube-system: $(can create secrets -n kube-system); read them: $(can get secrets -n kube-system)"
$K create namespace "$NS" >/dev/null && $K -n "$NS" create serviceaccount probe-target >/dev/null || { echo "setup failed" >&2; exit 1; }
cat <<'YAML' | $K -n "$NS" create $AS -f - >/dev/null || { echo "   the operator may NOT create the token Secret: the door is closed"; exit 0; }
apiVersion: v1
kind: Secret
metadata:
  name: probe-target-token
  annotations: {kubernetes.io/service-account.name: probe-target}
type: kubernetes.io/service-account-token
YAML
echo "   created a kubernetes.io/service-account-token Secret for ${NS}/probe-target as the operator"
L=0; for i in $(seq 1 10); do
  L=$($K -n "$NS" get secret probe-target-token $AS -o go-template='{{with index .data "token"}}{{len .}}{{else}}0{{end}}' 2>/dev/null || echo ERR)
  [ "$L" != ERR ] && [ "$L" -gt 0 ] 2>/dev/null && break; sleep 2; done
echo "   token filled in by the token controller and read back as the operator: length=${L} @$(el)"
[ "$L" != ERR ] && [ "$L" -gt 0 ] 2>/dev/null && echo "   RESULT: the door is open" || echo "   RESULT: no token obtained"
