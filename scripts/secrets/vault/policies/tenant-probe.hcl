# The throwaway tenant of the external-tenant auth experiment: one purpose-only entry, nothing else.
path "secret-lab/data/tenant-probe" { capabilities = ["read"] }
path "auth/token/lookup-self" { capabilities = ["read"] }
path "auth/token/renew-self" { capabilities = ["update"] }
path "auth/token/revoke-self" { capabilities = ["update"] }
