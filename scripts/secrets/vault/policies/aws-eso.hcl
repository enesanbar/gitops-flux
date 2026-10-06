# ESO in namespace secret-lab-aws: mint STS credentials for the read-only reader role, nothing else.
# create/update only: the generator POSTs, and a GET on this path would be a second minting route.
path "aws-lab/sts/eso-reader" { capabilities = ["create", "update"] }
path "auth/token/lookup-self" { capabilities = ["read"] }
path "auth/token/renew-self" { capabilities = ["update"] }
path "auth/token/revoke-self" { capabilities = ["update"] }
