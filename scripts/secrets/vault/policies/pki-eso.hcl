# ESO in namespace secret-lab-pki: request leaf certificates from the lab PKI role and read the
# platform's delivered certificate material, nothing else.
path "pki-lab/issue/lab" { capabilities = ["create", "update"] }
path "secret-lab/data/platform/*" { capabilities = ["read"] }
path "secret-lab/metadata/platform/*" { capabilities = ["read", "list"] }
path "auth/token/lookup-self" { capabilities = ["read"] }
path "auth/token/renew-self" { capabilities = ["update"] }
path "auth/token/revoke-self" { capabilities = ["update"] }
