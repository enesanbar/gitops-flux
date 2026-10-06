#!/usr/bin/env bash
# Filter: rendered chart manifests on stdin, the same manifests on stdout with the patch a Flux
# HelmRelease postRenderer carries applied through kustomize. Used to prove the patch offline against
# a chart render; the helm CLI here accepts only plugins as --post-renderer, and Flux applies its
# postRenderers inside helm-controller, so neither depends on this script.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
cat > "${work}/rendered.yaml"
cat > "${work}/kustomization.yaml" <<YAML
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: [rendered.yaml]
patches:
- target: {kind: ClusterRole, name: external-secrets-controller}
  path: patch.yaml
YAML
cp "${HERE}/strip-token-rule.patch.yaml" "${work}/patch.yaml"
kubectl kustomize "$work"
