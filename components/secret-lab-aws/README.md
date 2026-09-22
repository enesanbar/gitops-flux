# secret-lab-aws

The same logical application secrets as `trellis-secrets`, delivered from AWS Systems Manager
Parameter Store, two authentication shapes side by side:

- `aws-static`: a static access key in a Kubernetes Secret (`aws-credentials`, created by
  `scripts/secrets/aws-credentials.sh` from private custody, never committed). This is the most
  common shape, and the one the minted shape below replaces.
- `aws-vault-minted`: Vault's AWS secrets engine mints short-lived STS credentials for a read-only
  IAM role; ESO's `VaultDynamicSecret` generator writes them into `aws-sts-credentials`; the
  SecretStore reads them through `secretRef` including `sessionTokenSecretRef`. The credentials
  Secret is refreshed well inside the STS lifetime.

Parameter layout follows `<environment>-<cluster>/<application>/<name>`; the lab uses
`/lab-cluster00/`. The lab uses `us-west-1`. The Kustomization reconciles once
`aws-credentials.sh import` and `apply` have put a scoped key in place; without it nothing here can
sync, and `vault.sh aws` refuses to configure the minting engine.
