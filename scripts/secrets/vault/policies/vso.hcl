path "secret-lab/data/vso/*" { capabilities = ["read"] }
path "secret-lab/metadata/vso/*" { capabilities = ["read", "list"] }
# VSO renews on login and revokes cached tokens when releasing clients.
path "auth/token/lookup-self" { capabilities = ["read"] }
path "auth/token/renew-self" { capabilities = ["update"] }
path "auth/token/revoke-self" { capabilities = ["update"] }
