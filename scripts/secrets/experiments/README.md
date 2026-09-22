# Experiment-only material

Nothing here is wired into Flux and nothing here is a recommended pattern. Each directory holds
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
