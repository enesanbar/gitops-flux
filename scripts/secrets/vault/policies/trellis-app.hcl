# The Trellis process itself (its command-based key source): the key-encryption key and nothing else.
path "secret-lab/data/trellis/kek" { capabilities = ["read"] }
path "auth/token/revoke-self" { capabilities = ["update"] }
