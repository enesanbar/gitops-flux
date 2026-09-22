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
