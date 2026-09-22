# ESO in namespace secret-lab-aws: mint STS credentials for the read-only reader role, nothing else.
path "aws-lab/sts/eso-reader" { capabilities = ["create", "update", "read"] }
path "auth/token/lookup-self" { capabilities = ["read"] }
path "auth/token/renew-self" { capabilities = ["update"] }
path "auth/token/revoke-self" { capabilities = ["update"] }
