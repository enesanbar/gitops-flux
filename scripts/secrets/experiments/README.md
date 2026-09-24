# Experiment-only material

Nothing here is a recommended pattern, and nothing here is applied by Flux; where a Flux component
depends on one of these scripts, the component says so and this file names the order. Each directory holds
what one hands-on experiment needed, kept so the measurements recorded with it can be reproduced.

- `tenant-auth/` — a throwaway kind cluster on this lab's Docker network authenticating to the lab
  Vault as a tenant would to a platform Vault. `vault.sh tenant-auth enable|disable` manages the
  three auth mounts (Kubernetes auth with a tenant-issued reviewer token, JWT auth with the tenant's
  JWKS URL, JWT auth with a copied public key); the manifests are applied to the tenant with its own
  kubeconfig; the two scripts measure revocation and a network outage across the three methods.
- `kek-command/` — an application fetching its encryption key from Vault at process start through a
  command hook instead of reading a delivered Secret: a Node fetch script in a ConfigMap, a projected
  ServiceAccount token, and the chart values that wire them in. The scripts read secrets through
  pipes only and print lengths, never values.
- `pki/` — cert-manager issuing from the lab Vault PKI: `cert-manager-vault-issuer.sh apply` creates
  a dedicated ServiceAccount with a long-lived token Secret in `cert-manager`, the ClusterIssuer
  `vault-lab` carrying this machine's public Vault CA, and the `cm-leaf` Certificate in
  `secret-lab-pki`. Run `vault.sh pki` first (the mount, role and policies), then this script; the
  `secret-lab-pki` component itself needs neither. `delete` revokes the token and removes all three.
- `parity/` — the operator-version parity gate. `parity-gate.sh up` builds a throwaway kind cluster
  on this lab's Docker network running ESO 0.20.3 with the lab's own values, reaching the lab Vault
  through a temporary NodePort and the tenant auth mounts (it refuses to run while the `tenant-auth/`
  experiment holds them), and replays `components/trellis-secrets/` there byte-for-byte except for
  the store's auth mount and role. `parity-checks.sh <label> <kubectl target args>` then runs the
  same behavioural checks against any cluster — once against the lab (2.11.0), once against the
  throwaway — each in `secret-lab-eso` with its own `secret-lab/eso/parity-<label>/*` subtree,
  PASS/FAIL per check, exit status the number of failures. `parity-gate.sh remedy` strips chart
  0.20.3's cluster-wide token-creation rule with `strip-token-rule.patch.yaml` (the patch a Flux
  post-renderer would carry) and removes, then restores, the namespaced Role to show the store
  depends on it. `parity-gate.sh down` removes everything `up` created, and `up` runs it itself on
  any failure. The replay copies the lab application's live key-encryption key into the
  throwaway's etcd for as long as it exists. The parity scripts use the Python `yq` (the jq wrapper,
  `yq -y`/`yq -c`), not the Go implementation of the same name.
- `aws/` — the lab account's IAM, run by the account owner with an IAM-admin profile, never from the
  cluster. `base-iam.sh` creates what every Parameter Store experiment shares: an experiment user
  scoped to one prefix, a read-only role it may assume for the Vault-minted shape, a customer KMS key,
  and one access key written to a 0600 file. `tenant-iam.sh plan|apply|teardown` adds the stand-in
  for the one credential a tenant cluster is handed: it widens the experiment policy to the cluster
  realm `/devops/dev-cluster/` and the foreign realm `/dev-generic/`, creates a user that may only
  `ssm:GetParameter` there and decrypt through Parameter Store, and writes its two access keys
  straight to custody (`aws/tenant/a`, `aws/tenant/b`) so a rotation can be rehearsed. It refuses an
  account that lacks the base user and key. Tear down in reverse: `tenant-iam.sh teardown`, then
  `TEARDOWN=1 base-iam.sh`.
- `matrix/` — the rotation and failure/recovery rows, one script per row group, each printing
  statuses, key names, lengths and timings only. `lib.sh` is sourced by the others; export
  `SECRET_STATE_DIR`, and for `r1-backend-unavailable.sh` also `S5` (the release values file) and
  `CH` (the chart directory). Rows that need drift suspend the Flux Kustomization they touch and
  resume it; `r-aws-unreachable.sh` black-holes the SSM endpoint in CoreDNS and restores the live
  object afterwards.
  **These rows mutate a live cluster destructively**: they delete the Vault pod and the application's
  Secret, rotate real values in the backend, edit a policy file in place (an interrupted run leaves it
  narrowed) and patch cluster-wide CoreDNS. Run them against a lab and nothing else. Timing note: a
  bare `$(el)` next to a `$(waitfor …)` on one line reports when the wait BEGAN, because bash expands
  command substitutions left to right; `waitfor` therefore stamps its own return as `@+Ns`, and that
  trailing stamp is the measurement. Two rows answer questions the conventions rest on rather than
  failure modes: `r16-pinned-key-under-reloader.sh` (a version-pinned key restarts nothing under the
  reloader; an unpinned neighbour in the same Secret does) and `r17-operator-token-secret.sh` (whether
  the operator can obtain a token for any ServiceAccount through a service-account-token Secret, in a
  scratch namespace, printing the token's length only).
  `r-tenant-store.sh` measures the tenant store shape (`components/aws-parameterstore/` and the
  `ssm-app` reference): a pinned parameter version beside a rotating one, a JSON credential rotating
  as one, which namespaces may use the store and which paths they may read, the delivered credential
  rotated, revoked and restored underneath the store, two ExternalSecrets claiming one Secret, and the
  credential Secret going missing. `ROWS=ADE` runs a subset; it toggles the stand-in's IAM access keys
  and waits out their propagation rather than reading once.
