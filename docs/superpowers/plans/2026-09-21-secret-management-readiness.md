# Secret-management readiness

Goal: make Sealed Secrets, ESO, VSO and persistent Vault usable on the local kind
cluster before TASK-0669.02. This work makes no comparative recommendation and
does not change that task or any production cluster.

Framework: none; design depth: spec; execution topology: direct; model tier:
inherit; test ordering: normal for manifests, behavior tests for custody helpers.
Review depth: independent before integration.

## Design and boundaries

- Follow the existing shared component / dev overlay / Flux registry pattern.
- Pinned official charts: Sealed Secrets 2.20.0, ESO 2.10.0, Vault 0.34.1,
  VSO 1.5.1. Inspect their actual templates before selecting values.
- Keep operator releases, namespace-scoped provider configuration and examples
  separately reconciled. Dependency edges gate custom resources on ready CRDs.
- Vault uses one Raft member on pool-1 with a pre-bound retained PV. It is not HA
  and is not a dev-mode server. TLS uses the existing mkcert issuer. Manual
  unseal is deliberate; liveness tolerates sealed/uninitialized state while
  readiness requires unsealed state. Initialization and recovery run locally.
- Local custody: `.local/secret-management/dev-cluster/`, ignored, directories
  0700 and files 0600, outside kind bind mounts. Save keys before importing them.
  Never log credentials. Preserve the complete Sealed Secrets keyring, disable
  automatic renewal and offer explicit durable rotation. A required bootstrap
  ConfigMap volume prevents the controller starting before restore.
- Normal human auth uses userpass with a bounded policy and expiring tokens.
  Root is only bootstrap/emergency. ESO/VSO use separate Kubernetes service
  accounts, audience `vault`, short-lived tokens and disjoint KV paths.
- Examples use distinct namespaces and Secrets. Consumers mount Secret volumes,
  run without Kubernetes credentials, and prove updates by file content checks.
- Integrate metrics with existing Prometheus, configure security contexts,
  requests/limits and probes, retain CRDs on uninstall and review CRD upgrades.
- The cluster uses kindnet, which does not enforce NetworkPolicy. Do not claim
  network isolation from unenforced policies or replace the CNI in this task.

## Execution checklist

- [x] Inspect repository, live cluster, shared backlog context and official charts.
- [ ] Implement and behavior-test local custody helpers, restore and rotation.
- [ ] Add hardened operator releases, Vault TLS/storage, dependency registration.
- [ ] Add provider resources, scoped Vault policies/bootstrap and real examples.
- [ ] Render all overlays/charts; review sensitive handling and recovery paths.
- [ ] Commit/integrate GitOps changes and reconcile the local cluster.
- [ ] Initialize/unseal Vault; verify non-root CLI/UI and operator auth.
- [ ] Prove creation, updates and consumption for all three mechanisms.
- [ ] Simulate controller/key loss; restore and decrypt old ciphertext.
- [ ] Restart Vault/operators; prove recovery and metrics collection.
- [ ] Write concise operator instructions and a factual validation record.

## Verification commands

Run `python3 -m unittest discover -s scripts/secrets/tests`, shell syntax checks,
`kubectl kustomize` for each new overlay, and `helm template --include-crds` for
each pinned chart with the committed values. Run `scripts/secrets/validate.sh`
against `kind-local-dind-cluster`. Record live Flux revisions and actual results
in `docs/secret-management/VALIDATION.md`, including limits and any untested case.

Recreation contract: retain both the host-only custody directory and pool-1's
Vault directory (or a verified Raft snapshot plus its matching unseal keys), run
kind start + Flux bootstrap, then the local Vault recovery/bootstrap helper.
