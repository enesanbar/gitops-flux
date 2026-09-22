# cert-manager's Vault issuer: sign certificate requests with the lab PKI role, nothing else.
path "pki-lab/sign/lab" { capabilities = ["create", "update"] }
path "pki-lab/issue/lab" { capabilities = ["create", "update"] }
path "auth/token/lookup-self" { capabilities = ["read"] }
path "auth/token/renew-self" { capabilities = ["update"] }
