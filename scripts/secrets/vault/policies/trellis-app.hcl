# The Trellis process itself (TRELLIS_KEK_COMMAND): the key-encryption key and nothing else.
path "secret-lab/data/trellis/kek" { capabilities = ["read"] }
path "auth/token/lookup-self" { capabilities = ["read"] }
path "auth/token/revoke-self" { capabilities = ["update"] }
