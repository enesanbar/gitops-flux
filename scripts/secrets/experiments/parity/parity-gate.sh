#!/usr/bin/env bash
# Parity gate: do the reference manifests behave the same on the ESO version a tenant
# cluster runs (0.20.3) as on the lab's 2.11.0?
#
# A throwaway kind cluster joins the lab's docker network, installs ESO 0.20.3 with the
# fleet's value shape, and reaches the lab Vault as an outside cluster would. Two sets of
# ExternalSecrets run side by side, and the split is deliberate:
#   - the REFERENCE set is applied byte-for-byte from components/trellis-secrets/ and is
#     only ever read, because those paths hold the lab Trellis's live KEK: rotating one to
#     measure a refresh would make the running lab's encrypted data unreadable.
#   - the BEHAVIOUR set reads secret-lab/parity/* and is the only thing this script mutates.
# Only the SecretStore is adapted (auth mount and role), because the lab's own "kubernetes"
# mount reviews tokens from the lab's API server, not this cluster's; parity-store.diff
# records exactly what changed.
# Run from a worktree with SECRET_STATE_DIR pointing at the main checkout's private custody:
# the Vault helpers resolve it relative to the repository root, and a worktree has no .local/.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../../.." && pwd)"
CLUSTER=eso-parity
LAB_CONTEXT=kind-local-dind-cluster
LAB_NETWORK=kind-local-dind-cluster
ESO_VERSION=0.20.3
STATE="${PARITY_STATE:-${TMPDIR:-/tmp}/eso-parity}"
KCFG="${STATE}/kubeconfig"
mkdir -p "$STATE"

# Every call is pinned: kind writes current-context into ~/.kube/config, whose default
# context is a real tenant cluster.
kp() { kubectl --kubeconfig "$KCFG" "$@"; }
kl() { kubectl --context "$LAB_CONTEXT" "$@"; }
vault_cli() { "${REPO}/scripts/secrets/vault.sh" cli "$@"; }
el() { echo "+$(( $(date +%s) - T0 ))s"; }

up() {
  T0=$(date +%s)
  echo "[$(el)] creating throwaway kind cluster ${CLUSTER} on the lab network"
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER" || \
    KIND_EXPERIMENTAL_DOCKER_NETWORK="$LAB_NETWORK" kind create cluster --name "$CLUSTER" --kubeconfig "$KCFG" --wait 120s
  kind export kubeconfig --name "$CLUSTER" --kubeconfig "$KCFG" >/dev/null

  local node_ip lab_ip
  node_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${CLUSTER}-control-plane")"
  lab_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${LAB_CONTEXT#kind-}-control-plane")"
  echo "[$(el)] parity node ${node_ip}, lab node ${lab_ip}"

  echo "[$(el)] exposing the lab Vault on a NodePort for the parity cluster"
  kl -n vault get svc vault-nodeport >/dev/null 2>&1 || \
    kl -n vault expose svc vault --name=vault-nodeport --type=NodePort --port=8200 --target-port=8200 >/dev/null
  local nodeport
  nodeport="$(kl -n vault get svc vault-nodeport -o jsonpath='{.spec.ports[0].nodePort}')"
  echo "[$(el)] lab Vault reachable at ${lab_ip}:${nodeport}"

  # A selector-less Service plus a hand-written EndpointSlice makes the lab Vault answer at
  # vault.vault.svc:8200 inside this cluster, so the reference SecretStore's server URL - and
  # the SANs on the lab Vault's certificate - need no change at all.
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

  echo "[$(el)] installing external-secrets ${ESO_VERSION} with the fleet's value shape"
  helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
  helm --kubeconfig "$KCFG" upgrade --install external-secrets external-secrets/external-secrets \
    --version "$ESO_VERSION" --namespace external-secrets --create-namespace --wait --timeout 5m \
    -f "${HERE}/eso-values.yaml" >/dev/null
  kp -n external-secrets get deploy -o wide

  # jwt-tenant configures itself from jwks_url, and Vault presents no credential when it fetches
  # that URL, so the API server must serve OIDC discovery to unauthenticated callers. Kubernetes
  # binds system:service-account-issuer-discovery to authenticated service accounts only, which is
  # why the mount fails on a stock cluster. Granting it here is a throwaway-only shortcut and is
  # itself the finding: jwks_url is not usable against a tenant that keeps discovery closed, so
  # jwt-tenant-static (public keys copied once) is the shape that survives a real tenant.
  kp create clusterrolebinding oidc-discovery-unauthenticated \
    --clusterrole=system:service-account-issuer-discovery --group=system:unauthenticated \
    --dry-run=client -o yaml | kp apply -f - >/dev/null

  echo "[$(el)] enabling tenant auth mounts on the lab Vault for this cluster"
  "${REPO}/scripts/secrets/vault.sh" tenant-auth enable "$KCFG" "https://${node_ip}:6443"
  "${REPO}/scripts/secrets/vault.sh" parity enable

  echo "[$(el)] seeding the mutable parity subtree (never the live trellis/ paths)"
  seed_parity

  echo "[$(el)] applying the reference manifests"
  kp get ns trellis >/dev/null 2>&1 || kp create namespace trellis >/dev/null
  kl -n trellis get cm vault-ca -o jsonpath='{.data.ca\.crt}' > "${STATE}/vault-ca.crt"
  kp -n trellis create configmap vault-ca --from-file=ca.crt="${STATE}/vault-ca.crt" --dry-run=client -o yaml | kp apply -f - >/dev/null
  kp apply --validate=strict -f "${REPO}/components/trellis-secrets/rbac.yaml" >/dev/null
  kp apply --validate=strict -f "${HERE}/parity-store.yaml" >/dev/null
  kp apply --validate=strict -f "${REPO}/components/trellis-secrets/external-secrets.yaml"
  kp apply --validate=strict -f "${HERE}/parity-behaviour.yaml"

  diff -u "${REPO}/components/trellis-secrets/secret-store.yaml" "${HERE}/parity-store.yaml" \
    > "${STATE}/parity-store.diff" || true
  echo "[$(el)] SecretStore adaptation recorded in ${STATE}/parity-store.diff"
}

seed_parity() {
  # Shapes mirror the reference exactly; the values are generated here and used nowhere else.
  vault_cli kv put secret-lab/parity/kek TRELLIS_KEK="$(openssl rand -base64 32 | tr -d '\n')" >/dev/null
  vault_cli kv put secret-lab/parity/service-token TRELLIS_SERVICE_TOKEN="$(openssl rand -hex 16 | tr -d '\n')" >/dev/null
  vault_cli kv put secret-lab/parity/llm TRELLIS_LLM_API_KEY="sk-parity-$(openssl rand -hex 8 | tr -d '\n')" >/dev/null
  vault_cli kv put secret-lab/parity/embedding TRELLIS_EMBEDDING_API_KEY="sk-parity-$(openssl rand -hex 8 | tr -d '\n')" >/dev/null
  local crt key
  crt="$(kl -n vault get secret vault-server-tls -o go-template='{{index .data "tls.crt"}}' | base64 -d)"
  key="$(openssl genrsa 2048 2>/dev/null)"
  vault_cli kv put secret-lab/parity/tls tls.crt="$crt" tls.key="$key" >/dev/null
  vault_cli kv put secret-lab/parity/composed A=alpha B=bravo C=charlie >/dev/null
}

down() {
  T0=$(date +%s)
  echo "[$(el)] tearing down the parity cluster and everything it added"
  kind delete cluster --name "$CLUSTER" --kubeconfig "$KCFG" 2>/dev/null || true
  kl -n vault delete svc vault-nodeport --ignore-not-found >/dev/null || true
  # Order matters: disabling the mount would take the role with it and leave the policy behind.
  "${REPO}/scripts/secrets/vault.sh" parity disable || true
  "${REPO}/scripts/secrets/vault.sh" tenant-auth disable || true
  vault_cli kv metadata delete secret-lab/parity/kek >/dev/null 2>&1 || true
  vault_cli kv metadata delete secret-lab/parity/service-token >/dev/null 2>&1 || true
  vault_cli kv metadata delete secret-lab/parity/llm >/dev/null 2>&1 || true
  vault_cli kv metadata delete secret-lab/parity/embedding >/dev/null 2>&1 || true
  vault_cli kv metadata delete secret-lab/parity/tls >/dev/null 2>&1 || true
  vault_cli kv metadata delete secret-lab/parity/composed >/dev/null 2>&1 || true
  rm -f "$KCFG"
  echo "[$(el)] done"
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  *) echo "Usage: parity-gate.sh up|down (checks live in parity-checks.sh)" >&2; exit 2 ;;
esac
