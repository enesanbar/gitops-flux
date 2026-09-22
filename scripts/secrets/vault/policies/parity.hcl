# The parity cluster's ESO. Read-only on the trellis subtree, because the parity gate replays the
# reference ExternalSecrets against it verbatim and must never write there: those paths hold the
# running lab Trellis's key-encryption key. The parity subtree is the one the gate rotates and
# deletes, and list is required there because a dataFrom.find check enumerates it.
path "secret-lab/data/trellis/*"     { capabilities = ["read"] }
path "secret-lab/metadata/trellis/*" { capabilities = ["read", "list"] }
path "secret-lab/data/parity/*"      { capabilities = ["read"] }
path "secret-lab/metadata/parity/*"  { capabilities = ["read", "list"] }
path "auth/token/lookup-self" { capabilities = ["read"] }
path "auth/token/renew-self"  { capabilities = ["update"] }
path "auth/token/revoke-self" { capabilities = ["update"] }
