# Local readiness validation — 2026-09-21

Target: `kind-local-dind-cluster`, Kubernetes **v1.35.1**, one kind node.
Initial repository revision: `71be567`. Infrastructure installed through Flux
from `75320d2`, with isolated Sealed Secrets wiring in `5ac78af` and the GitOps
reseal/update exercise in **`e3cf814`**. No production cluster was changed.

The initial cluster had no running Sealed Secrets, ESO, VSO or Vault installation.
Sealed Secrets existed only as an unregistered old shared manifest; its chart URL
returned 404. Nothing here chooses a mechanism: this validates the lab the
experiments run on.

## Installed and exercised

| Component | Pinned chart | Running application | Result |
| --- | --- | --- | --- |
| Sealed Secrets | 2.20.0 | 0.40.0 | HelmRelease Ready |
| ESO | 2.10.0 | 2.10.0 | HelmRelease Ready; all three deployments healthy |
| Vault | 0.34.1 | 2.0.4 | HelmRelease Ready; initialized, unsealed, persistent Raft |
| VSO | 1.5.1 | 1.5.1 | HelmRelease Ready; controller and metrics proxy healthy |

All eight new Flux Kustomizations reached Ready. The three consumers are Running
and Available, in separate `secret-lab-{sealed,eso,vso}` namespaces.

| Exercise | Observed evidence |
| --- | --- |
| Sealed creation | Normal Secret piped to `kubeseal`; ciphertext committed/pushed; Flux applied it; owned Secret and workload contained version 1 |
| Sealed update | Resealed version 2 committed as `e3cf814`; Flux reconciled; consumer contained version 2 |
| Durable rotation | New 4096-bit RSA key saved on host before import; controller restarted; active certificate matched `current.pem`; historical key retained |
| Key-loss recovery | Controller stopped, **both** in-cluster sealing keys and bootstrap gate deleted; host keyring restored; controller restarted; generated example Secret deleted to force fresh decryption; unchanged ciphertext sealed with the old key decrypted to the same value |
| Vault human login | Userpass `operator` obtained a token with `secret-lab-operator` and no `root` policy; normal CLI wrote/read/updated both example paths; create/read/update/soft-delete/undelete/metadata-delete and policy/auth inspection also passed on an isolated temporary path |
| Vault UI | Verified TLS HTTP response and rendered browser page at `https://vault.kindcluster.dev/ui/vault/auth`, displaying “Sign in to Vault” and Userpass option |
| ESO | SecretStore Ready; ExternalSecret SecretSynced; Vault versions 1 and 2 reached the separately owned Secret and mounted workload file |
| VSO | VaultStaticSecret Synced/Healthy/Ready; Vault versions 1 and 2 reached its separately owned Secret and workload; update restarted its Deployment |
| Auth boundaries | ESO/VSO native SA login, own-path read and token self-renew/revoke succeeded; other subtree and other role login returned 403 |
| ESO TokenRequest RBAC | Allowed for `secret-lab-eso/vault-auth`; denied for `default/default` |
| Controller restarts | Restarted all ESO deployments and VSO; subsequent synchronization/auth checks passed |
| Vault restart | Deleted only `vault-0`; replacement initially Running/unready with zero restarts, then unsealed using host key; previous token, policies, auth and both KV version-2 values remained usable |
| Persistent storage | `vault-data` Retain PV bound to `vault/data-vault-0`, backed by `/mnt/data-pool-1/vault-data` on the host bind mount |
| Backup | Raft snapshot saved privately and `vault operator raft snapshot inspect` succeeded |
| Monitoring | Six active Prometheus targets healthy: Sealed, three ESO targets, VSO and Vault; all healthy again after restart |
| Custody | Private tree permission check passed; `.local` ignored; staged credential scan found no private key or Vault token |

## Repeatable checks

```bash
python3 -m unittest discover -s scripts/secrets/tests
bash -n scripts/secrets/*.sh scripts/flux/bootstrap.sh
./scripts/secrets/validate.sh
./scripts/secrets/validate-auth.sh
# Explicit simulation that removes and restores only the controller keys/example:
./scripts/secrets/recover-sealed.sh --simulate-key-loss
```

Five custody behavior tests passed, covering file/directory permissions, atomic
private writes, symlink rejection, historical key preservation and conflicting
key refusal. All eight dev overlays and the root cluster Kustomization rendered.
All four downloaded pinned charts rendered, including VSO's Flux TLS patches.
An independent review identified and verified fixes for writable Vault `/tmp`,
noninteractive unseal, and VSO token self-renewal permissions. The live run also
exercised and fixed immediate successive local port-forward sessions.

## Limits of this evidence

- The existing whole cluster was not deleted: unrelated services use it. Sealed
  key loss/controller recreation and actual Vault/controller pod restarts were
  exercised. Full cluster recreation follows the retained host-pool design and
  documented bootstrap sequence but was not executed in this run.
- A Raft snapshot was exported and inspected; disaster recovery onto a fresh
  empty Vault from that snapshot was not exercised.
- The browser login screen and TLS route were tested; browser form submission
  was not automated. Userpass authentication itself was exercised through Vault.
- kindnet does not enforce NetworkPolicy. This is single-node infrastructure,
  with manual Vault unseal and local single-custodian recovery material.
- The committed SealedSecret deliberately still uses the historical key, proving
  that rotation/restoration retains decryptability. New sealing uses the rotated
  public certificate. Both keys remain in private custody.

These checks establish local operational readiness, not a production deployment
certification or a comparison/recommendation among the three mechanisms.
