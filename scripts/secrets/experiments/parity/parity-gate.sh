#!/usr/bin/env bash
# Parity gate: do the reference manifests behave the same on ESO 0.20.3 as on the lab's 2.11.0?
#
# A throwaway kind cluster joins the lab's Docker network, installs chart 0.20.3 with the lab's own
# values, and reaches the lab Vault as a cluster outside it would. Subcommands:
#   up      build the throwaway, replay components/trellis-secrets/ on it byte-for-byte (only the
#           SecretStore's auth mount and role differ), and provision secret-lab-eso for the
#           behaviour checks. Replaying the reference copies the lab application's live
#           key-encryption key into the throwaway's etcd for as long as it exists: acceptable for a
#           cluster on this machine's Docker network that lives for minutes, and the reason `down`
#           is not optional.
#   remedy  the chart-0.20.3 RBAC question, two-sided: strip the controller's cluster-wide
#           serviceaccounts/token rule with the patch a Flux postRenderer would carry, then prove
#           the namespaced Role is what keeps the store working by removing it and watching it fail.
#   down    remove everything `up` created, and only that.
# The behaviour checks themselves are parity-checks.sh, run once against each cluster.
#
# Run from a worktree with SECRET_STATE_DIR pointing at the main checkout's private custody: the
# Vault helpers resolve it relative to the repository root, and a worktree has no .local/.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../../.." && pwd)"
CLUSTER=eso-parity
LAB_CONTEXT=kind-local-dind-cluster
LAB_NETWORK=kind-local-dind-cluster
ESO_VERSION=0.20.3
STATE="${PARITY_STATE:-${TMPDIR:-/tmp}/eso-parity}"
KCFG="${STATE}/kubeconfig"

# Every call names its kubeconfig or context: the machine's default context may be a real cluster,
# and kind is always handed --kubeconfig so it never writes the default file.
kp() { kubectl --kubeconfig "$KCFG" "$@"; }
kl() { kubectl --context "$LAB_CONTEXT" "$@"; }
vsh() { "${REPO}/scripts/secrets/vault.sh" "$@"; }
T0=$(date +%s); el() { echo "+$(( $(date +%s) - T0 ))s"; }
waitfor() { local max=$1 exp=$3 i v; for i in $(seq 1 $((max/5))); do v=$(eval "$2"); [ "$v" = "$exp" ] && { echo "$v @$(el)"; return 0; }; sleep 5; done; echo "${v:-empty}(timeout) @$(el)"; return 1; }
esr() { kp -n "$1" get externalsecret "$2" -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null; }
keys() { kp -n "$1" get secret "$2" -o go-template='{{range $k,$v := .data}}{{$k}}({{len $v}}) {{end}}' 2>/dev/null; }
sync() { kp -n "$1" annotate externalsecret "$2" force-sync="$(date +%s%N)" --overwrite >/dev/null; }
refreshed() { kp -n "$1" get externalsecret "$2" -o jsonpath='{.status.refreshTime}' 2>/dev/null; }
# <reference store file> <role in it> <role to use>: the store with only its auth mount and role
# changed, printed with the diff that proves nothing else moved (two lines out, two in).
adapt_store() {
  local out; out=$(sed -e 's|mountPath: kubernetes$|mountPath: kubernetes-tenant|' -e "s|role: $2\$|role: $3|" "$1")
  local changed; changed=$(diff "$1" <(printf '%s\n' "$out") | grep -c '^[<>]')
  [ "$changed" = 4 ] || { echo "adapting $1 changed ${changed} lines, not 4; refusing to call it the reference" >&2; return 1; }
  echo "--- $(basename "$1"), adapted for this cluster (asserted: only these lines differ) ---" >&2
  diff "$1" <(printf '%s\n' "$out") >&2 || true
  printf '%s\n' "$out"
}
can_mint() { kp auth can-i create "serviceaccounts${2:+/$2}" --subresource=token -n "$1" \
  --as=system:serviceaccount:external-secrets:external-secrets 2>/dev/null || true; }

up() {
  mkdir -p "$STATE"
  # The three tenant auth mounts belong to the tenant-auth experiment. Repointing them at this
  # throwaway would silently break that experiment, and disabling them afterwards would destroy it.
  # Fail closed: an expired operator login makes the listing fail, and treating that as "no mounts"
  # would let tenant-auth enable repoint an experiment's live mounts as root.
  local mounts
  mounts=$(vsh cli auth list -format=json 2>/dev/null) || { echo "Cannot list Vault auth mounts; run 'vault.sh login' first." >&2; exit 1; }
  if jq -e 'has("kubernetes-tenant/") or has("jwt-tenant/") or has("jwt-tenant-static/")' <<<"$mounts" >/dev/null; then
    echo "The tenant auth mounts are already enabled (the tenant-auth experiment owns them)." >&2
    echo "Finish that experiment and run 'vault.sh tenant-auth disable' first." >&2; exit 1
  fi
  # A half-built gate leaves the lab Vault on a NodePort of the shared Docker network, so any exit
  # before the end of up tears down. An EXIT trap with a flag rather than an ERR trap: ERR does not
  # fire inside a function without errtrace, and with errtrace it would also fire inside the polling
  # command substitutions, tearing the cluster down over a lookup that simply had no answer yet.
  UP_DONE=0
  trap '[ "$UP_DONE" = 1 ] || { echo "[$(el)] up did not finish; tearing down what it created" >&2; down; }' EXIT

  echo "[$(el)] creating throwaway kind cluster ${CLUSTER} on the lab network"
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER" || \
    KIND_EXPERIMENTAL_DOCKER_NETWORK="$LAB_NETWORK" kind create cluster --name "$CLUSTER" --kubeconfig "$KCFG" --wait 120s
  kind export kubeconfig --name "$CLUSTER" --kubeconfig "$KCFG" >/dev/null

  local node_ip lab_ip nodeport
  node_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${CLUSTER}-control-plane")"
  lab_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${LAB_CONTEXT#kind-}-control-plane")"
  kl -n vault get svc vault-nodeport >/dev/null 2>&1 || \
    kl -n vault expose svc vault --name=vault-nodeport --type=NodePort --port=8200 --target-port=8200 >/dev/null
  nodeport="$(kl -n vault get svc vault-nodeport -o jsonpath='{.spec.ports[0].nodePort}')"
  echo "[$(el)] parity node ${node_ip}; lab Vault at ${lab_ip}:${nodeport}"

  # A selector-less Service plus a hand-written EndpointSlice makes the lab Vault answer at
  # vault.vault.svc:8200 here, so the reference store's server URL and the SANs on the lab Vault's
  # certificate need no change at all.
  kp get ns vault >/dev/null 2>&1 || kp create namespace vault >/dev/null
  cat <<YAML | kp apply -f - >/dev/null
apiVersion: v1
kind: Service
metadata: {name: vault, namespace: vault}
spec:
  ports: [{name: https, port: 8200, protocol: TCP}]
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata: {name: vault, namespace: vault, labels: {kubernetes.io/service-name: vault}}
addressType: IPv4
ports: [{name: https, port: ${nodeport}, protocol: TCP}]
endpoints: [{addresses: ["${lab_ip}"], conditions: {ready: true}}]
YAML

  echo "[$(el)] installing external-secrets ${ESO_VERSION} with the lab's values"
  # Repository config and cache live in the gate's own state: with --repo, helm still reads every
  # configured repository's cached index, so one stale entry on the host fails the install.
  helm --kubeconfig "$KCFG" --repository-config "${STATE}/helm-repositories.yaml" \
    --repository-cache "${STATE}/helm-cache" upgrade --install external-secrets external-secrets \
    --repo https://charts.external-secrets.io --version "$ESO_VERSION" \
    --namespace external-secrets --create-namespace --wait --timeout 5m -f "${HERE}/eso-values.yaml" >/dev/null
  kp -n external-secrets get deploy external-secrets -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

  # jwt-tenant configures itself from jwks_url, and Vault presents no credential when it fetches it,
  # so the API server must serve OIDC discovery to unauthenticated callers. Kubernetes binds
  # system:service-account-issuer-discovery to authenticated service accounts only. Granting it is a
  # throwaway-only shortcut, and is itself the finding: jwks_url is unusable against a cluster that
  # keeps discovery closed, which leaves copied public keys as the JWT shape that survives one.
  kp create clusterrolebinding oidc-discovery-unauthenticated \
    --clusterrole=system:service-account-issuer-discovery --group=system:unauthenticated \
    --dry-run=client -o yaml | kp apply -f - >/dev/null

  echo "[$(el)] tenant auth mounts and the parity roles on the lab Vault"
  # The marker goes first: the mounts did not exist a moment ago, so from here on they are this run's
  # to remove, including after a partial enable.
  touch "${STATE}/created-tenant-auth"
  vsh tenant-auth enable "$KCFG" "https://${node_ip}:6443"
  vsh parity enable

  local ca="${STATE}/vault-ca.crt"
  kl -n trellis get cm vault-ca -o jsonpath='{.data.ca\.crt}' > "$ca"

  echo "[$(el)] replaying the reference manifests"
  kp get ns trellis >/dev/null 2>&1 || kp create namespace trellis >/dev/null
  kp -n trellis create configmap vault-ca --from-file=ca.crt="$ca" --dry-run=client -o yaml | kp apply -f - >/dev/null
  kp apply --validate=strict -f "${REPO}/components/trellis-secrets/rbac.yaml" >/dev/null
  # The reference store with exactly two lines changed, both forced by the cluster boundary rather
  # than the operator version: this Vault reviews the throwaway's tokens through a second mount, and
  # the role is bound to the throwaway's ServiceAccount. Generated, not copied, and asserted.
  adapt_store "${REPO}/components/trellis-secrets/secret-store.yaml" trellis parity > "${STATE}/reference-store.yaml"
  kp apply --validate=strict -f "${STATE}/reference-store.yaml" >/dev/null
  kp apply --validate=strict -f "${REPO}/components/trellis-secrets/external-secrets.yaml" >/dev/null

  echo "[$(el)] provisioning secret-lab-eso for the behaviour checks, identity copied from components/secret-stores/"
  yq -y 'select(.metadata.namespace=="secret-lab-eso" or .metadata.name=="secret-lab-eso")' \
    "${REPO}/components/secret-stores/namespaces.yaml" | kp apply --validate=strict -f - >/dev/null
  kp -n secret-lab-eso create configmap vault-ca --from-file=ca.crt="$ca" --dry-run=client -o yaml | kp apply -f - >/dev/null
  adapt_store "${REPO}/components/secret-stores/eso-vault.yaml" eso parity-behaviour | kp apply --validate=strict -f - >/dev/null

  echo "[$(el)] reference set on ${ESO_VERSION}"
  local n
  for n in trellis-secrets trellis-tls-eso; do
    r=$(waitfor 180 "esr trellis ${n}" SecretSynced) || { echo "   ${n}: ${r} - the reference does not sync here" >&2; exit 1; }
    echo "   ${n}: ${r} type=$(kp -n trellis get secret "$n" -o jsonpath='{.type}') keys=$(keys trellis "$n")"
  done
  echo "   the replayed ExternalSecrets are components/trellis-secrets/external-secrets.yaml at $(git -C "$REPO" rev-parse --short HEAD)$(git -C "$REPO" diff --quiet -- components/trellis-secrets || echo ' PLUS UNCOMMITTED CHANGES')"
  UP_DONE=1
  echo "[$(el)] up complete; next: parity-checks.sh against both clusters, then remedy, then down"
}

remedy() {
  local fails=0 began
  ok() { echo "   PASS $*"; }; bad() { echo "   FAIL $*"; fails=$((fails+1)); }
  echo "=== RBAC remedy on ${ESO_VERSION}, $(date -u +%FT%TZ) ==="
  echo "-- R0 as installed"
  [ "$(can_mint kube-system)" = yes ] && ok "operator may mint a token for any ServiceAccount (kube-system: yes)" \
                                      || bad "expected the chart's cluster-wide grant to be present"
  echo "-- R1 strip the cluster-wide rule with the postRenderer patch"
  kp patch clusterrole external-secrets-controller --type=json -p "$(yq -c . "${HERE}/strip-token-rule.patch.yaml")" >/dev/null
  [ "$(can_mint kube-system)" = no ] && ok "kube-system: no" || bad "rule still effective in kube-system"
  [ "$(can_mint trellis vault-auth)" = yes ] && ok "trellis/vault-auth: yes (the namespaced Role)" || bad "trellis/vault-auth lost"
  [ "$(can_mint trellis default)" = no ] && ok "trellis/default: no (resourceNames holds)" || bad "trellis/default still mintable"
  echo "-- R2 the reference store still works on the namespaced Role alone"
  # Already green before the sync, so the reason alone proves nothing: wait for a newer refresh.
  local before; before=$(refreshed trellis trellis-secrets)
  sync trellis trellis-secrets; began=$(el)
  r=$(waitfor 60 "[ \"\$(refreshed trellis trellis-secrets)\" != '${before}' ] && esr trellis trellis-secrets" SecretSynced) \
    && ok "trellis-secrets re-synced ${r} [sync ${began}]" || bad "trellis-secrets did not re-sync: ${r}"
  echo "-- R3 remove the namespaced Role: the store must now fail, proving the Role is load-bearing"
  kp -n trellis delete role eso-vault-token >/dev/null
  sync trellis trellis-secrets; began=$(el)
  r=$(waitfor 90 'esr trellis trellis-secrets' SecretSyncedError) && ok "trellis-secrets ${r} [sync ${began}]" || bad "trellis-secrets ${r}"
  echo "   cause (latest warning event): $(kp -n trellis get events --field-selector involvedObject.name=trellis-secrets,type=Warning \
    --sort-by=.lastTimestamp -o jsonpath='{.items[-1:].message}' 2>/dev/null | cut -c1-220)"
  echo "   Secret kept under Retain: keys=$(keys trellis trellis-secrets)"
  echo "-- R4 restore the Role: the store recovers"
  kp apply -f "${REPO}/components/trellis-secrets/rbac.yaml" >/dev/null
  sync trellis trellis-secrets; began=$(el)
  r=$(waitfor 90 'esr trellis trellis-secrets' SecretSynced) && ok "trellis-secrets ${r} [sync ${began}]" || bad "trellis-secrets ${r}"
  echo "=== remedy: ${fails} failure(s) ==="
  return "$fails"
}

down() {
  echo "[$(el)] removing what up created"
  kind delete cluster --name "$CLUSTER" --kubeconfig "$KCFG" >/dev/null 2>&1 || true
  kl -n vault delete svc vault-nodeport --ignore-not-found >/dev/null || true
  # Order matters: disabling the mount first would take the roles with it and hide a failed delete.
  vsh parity disable || true
  if [ -e "${STATE}/created-tenant-auth" ]; then vsh tenant-auth disable || true; fi
  rm -rf "$STATE"
  echo "[$(el)] down complete"
}

case "${1:-}" in
  up) up ;;
  remedy) remedy ;;
  down) down ;;
  *) echo "Usage: parity-gate.sh up|remedy|down" >&2; exit 2 ;;
esac
