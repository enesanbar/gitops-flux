# secret-lab-aws (awaiting credentials)

The same logical application secrets as `trellis-secrets`, delivered from AWS Systems Manager
Parameter Store, two authentication shapes side by side:

- `aws-static`: a static access key in a Kubernetes Secret (`aws-credentials`, created by
  `scripts/secrets/aws-credentials.sh` from private custody, never committed). This is the shape a
  fleet typically runs today.
- `aws-vault-minted`: Vault's AWS secrets engine mints short-lived STS credentials for a read-only
  IAM role; ESO's `VaultDynamicSecret` generator writes them into `aws-sts-credentials`; the
  SecretStore reads them through `secretRef` including `sessionTokenSecretRef`. The credentials
  Secret is refreshed well inside the STS lifetime.

Parameter layout follows `<environment>-<island>/<application>/<name>`; the lab uses
`/lab-island00/`. `REGION` is the placeholder replaced when credentials arrive. The Flux
Kustomization is `suspend: true` until then.
