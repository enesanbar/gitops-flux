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
