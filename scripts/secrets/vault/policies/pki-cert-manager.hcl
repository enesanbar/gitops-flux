# cert-manager's Vault issuer: sign certificate requests with the lab PKI role, nothing else. Never
# "issue", which would let Vault generate the private key the requester should hold alone.
path "pki-lab/sign/lab" { capabilities = ["create", "update"] }
path "auth/token/lookup-self" { capabilities = ["read"] }
path "auth/token/renew-self" { capabilities = ["update"] }
