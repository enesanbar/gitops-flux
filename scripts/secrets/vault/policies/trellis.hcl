# ESO's SecretStore in the trellis namespace: read-only on the application's subtree.
path "secret-lab/data/trellis/*" { capabilities = ["read"] }
path "secret-lab/metadata/trellis/*" { capabilities = ["read", "list"] }
path "auth/token/lookup-self" { capabilities = ["read"] }
path "auth/token/renew-self" { capabilities = ["update"] }
path "auth/token/revoke-self" { capabilities = ["update"] }
