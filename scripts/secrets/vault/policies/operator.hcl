# Human experimentation is confined to this KV mount, not system administration.
path "secret-lab/data/*" {
  capabilities = ["create", "read", "update", "delete", "patch"]
}
path "secret-lab/metadata/*" {
  capabilities = ["read", "list", "delete", "update"]
}
path "secret-lab/delete/*" { capabilities = ["update"] }
path "secret-lab/undelete/*" { capabilities = ["update"] }
path "secret-lab/destroy/*" { capabilities = ["update"] }
path "sys/mounts" { capabilities = ["read"] }
path "sys/auth" { capabilities = ["read"] }
path "sys/policies/acl" { capabilities = ["list"] }
path "sys/policies/acl/*" { capabilities = ["read"] }
path "auth/kubernetes/role" { capabilities = ["list"] }
path "auth/kubernetes/role/*" { capabilities = ["read"] }
