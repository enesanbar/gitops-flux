# Secret-management operator guide

Run commands from the repository root. Target: `kind-local-dind-cluster` only.
This prepares experiments for **TASK-0669.02**; it does not choose a mechanism.

Prerequisites: `kubectl`, `flux`, `helm`, `kubeseal`, `vault`, `mkcert`, `jq`,
`openssl`, `python3`, and the existing kind/Docker environment. Every helper
sets its Kubernetes context explicitly. Do not run secret helpers with tracing.

| Layer | Location |
| --- | --- |
| Operators and Vault | `components/{sealed-secrets,external-secrets,vault,vault-secrets-operator}` |
| Enabled components, storage, Flux dependencies | `clusters/dev-cluster/components/infrastructure/` |
| ESO/VSO provider configuration | `components/secret-stores/` |
| Independent real examples | `components/secret-example-{sealed,eso,vso}/` |
| Host bootstrap and policies | `scripts/secrets/` |
| Private custody (never Git, never a node mount) | `.local/secret-management/dev-cluster/` |
| Vault encrypted Raft data (kind bind mount) | `scripts/cluster-setup/kind/data-pool-1/vault-data/` |

Directories under private custody are `0700`, files `0600`; scripts reject
symlinks and non-ignored custody paths. `.gitignore` excludes `.local/`, data
pools and common private-key/export names. The host account and disk encryption
protect these files; mode bits do not protect against host root or disk loss.
Keep an encrypted backup on a separate disk. Never paste `init.json`, private
keys, passwords or token files into a task, log, issue or commit.

## Sealed Secrets: seal, change, inspect

The full historical keyring is `sealed-secrets/keys.json` under private custody;
`sealed-secrets/current.pem` is the public sealing certificate. Bootstrap imports
the keyring **before** Flux starts the controller. A mandatory ConfigMap volume
holds the controller pending if bootstrap was skipped. `restore` does not invent
new keys when recovery material is missing.

Create a real Secret locally and pipe it directly into `kubeseal`:

```bash
umask 077
mkdir -p .local/secret-management/dev-cluster/input
# Put the secret value in this private file using your editor; do not use a literal
# password in a shell command, which would save it in shell history.
${EDITOR:-vi} .local/secret-management/dev-cluster/input/message
kubectl --context kind-local-dind-cluster -n secret-lab-sealed \
  create secret generic sealed-example \
  --from-file=message=.local/secret-management/dev-cluster/input/message \
  --dry-run=client -o json |
kubeseal --cert .local/secret-management/dev-cluster/sealed-secrets/current.pem \
  --format yaml > components/secret-example-sealed/secret.yaml
kubectl kustomize clusters/dev-cluster/components/infrastructure/secret-example-sealed >/dev/null
git add components/secret-example-sealed/secret.yaml
git commit -m 'test(secrets): reseal the isolated example'
git push origin main
flux --context kind-local-dind-cluster reconcile kustomization secret-example-sealed --with-source
kubectl --context kind-local-dind-cluster -n secret-lab-sealed get sealedsecret sealed-example
kubectl --context kind-local-dind-cluster -n secret-lab-sealed get secret sealed-example
```

Use the same command to update: change the private input file and reseal. Strict
scope binds ciphertext to **both name and namespace**; changing either requires
resealing. Only ciphertext goes into Git. Remove private input when no longer
needed. The example consumer reads `/secrets/message` from a volume; propagation
can take about a minute. No credential is printed in its logs.

```bash
kubectl --context kind-local-dind-cluster -n secret-lab-sealed describe sealedsecret sealed-example
kubectl --context kind-local-dind-cluster -n sealed-secrets logs deployment/sealed-secrets-controller --tail=50
./scripts/secrets/sealed-key.sh backup
./scripts/secrets/sealed-key.sh restore
# For an already running controller, reload its in-memory key registry:
kubectl --context kind-local-dind-cluster -n sealed-secrets rollout restart deployment/sealed-secrets-controller
```

Automatic in-cluster key renewal is disabled deliberately: an automatically
generated key could otherwise seal new Git content before a host backup exists.
Rotate at least every 90 days, or immediately after suspected exposure:

```bash
./scripts/secrets/sealed-key.sh rotate
kubeseal --context kind-local-dind-cluster --controller-namespace sealed-secrets \
  --controller-name sealed-secrets-controller --re-encrypt --format yaml \
  < components/secret-example-sealed/secret.yaml > .local/resealed.yaml
mv .local/resealed.yaml components/secret-example-sealed/secret.yaml
# Commit/push as above, then refresh your external encrypted custody backup.
```

Rotation saves the new private key **before import**, retains every old key, and
restarts the controller. Never discard old keys while historical Git ciphertext
or backups may need them. Key rotation does not rotate the underlying application
credential; replace compromised application credentials separately.

First setup on a genuinely new host: `sealed-key.sh init --new-environment`, then
`prepare-local.sh`, then reseal examples for that new key. This flag deliberately
creates a different environment; it is **not** a recovery command.

## Vault: CLI and UI

Vault is a TLS-enabled, persistent single-member Raft server, **not `-dev`**.
Use the local ingress [Vault UI](https://vault.kindcluster.dev/ui/). In-cluster
clients connect to `https://vault.vault.svc:8200`, validating the same local CA.
The ingress also verifies TLS to Vault. No `VAULT_SKIP_VERIFY` is needed.

After first install, or when recovering:

```bash
./scripts/secrets/prepare-local.sh
./scripts/secrets/vault.sh bootstrap
./scripts/secrets/vault.sh login
source scripts/secrets/vault-env.sh
vault token lookup                      # policies must not include root
vault kv put secret-lab/eso/example message=eso-ready-v1
vault kv put secret-lab/vso/example message=vso-ready-v1
vault kv get secret-lab/eso/example
vault kv put secret-lab/eso/example message=eso-ready-v2
vault kv delete secret-lab/eso/example  # soft-delete newest version
vault kv undelete -versions=2 secret-lab/eso/example
vault auth list
vault policy list
vault policy read secret-lab-eso
vault read auth/kubernetes/role/eso
```

The displayed values are explicitly non-sensitive example strings. For real
values, use `message=@/path/to/private/file`. `vault kv metadata delete` destroys
all versions of a path; use only when that is your intent.

The normal account is **operator**, userpass mount `userpass`, policy
`secret-lab-operator`, with 1-hour tokens (4-hour maximum). It can operate the
`secret-lab` KV v2 mount and inspect policies/auth metadata; it cannot administer
Vault. `vault.sh login` loads the password privately and saves a normal token.
Re-run it when the token expires, then source `vault-env.sh` again. Alternatively
use `vault.sh cli kv get secret-lab/eso/example` without exporting a token.

For UI login choose **Userpass**, mount `userpass`, username **operator**. Retrieve the
password privately from `.local/secret-management/dev-cluster/vault/operator-password`
using your editor/password manager. To use interactive `vault login` instead:

```bash
source scripts/secrets/vault-env.sh
unset VAULT_TOKEN
vault login -method=userpass username=operator
# Enter the password at the hidden prompt. This stores a normal token in
# ~/.vault-token; the helper itself never writes that file.
```

`vault/init.json` contains the emergency root token and the Shamir unseal key.
Only explicit `bootstrap` and `snapshot` use root. This local single-custodian
setup uses one key/share; it does not pretend to offer multi-person custody.
Production needs an independently chosen HA, seal/KMS, identity and custody plan.
Never copy these development credentials into another environment.

Policies are reviewed files in `scripts/secrets/vault/policies/`. Re-run
`vault.sh bootstrap` to apply a deliberate policy/role change. Kubernetes auth
uses Vault's projected service-account token as the TokenReview identity, with
the chart's `system:auth-delegator` binding. Client tokens use audience `vault`,
specific namespace/SA bindings, 10-minute TTL and 1-hour maximum. Vault refreshes
its own projected reviewer token; no long-lived Kubernetes reviewer Secret exists.

## ESO

`components/secret-stores/eso-vault.yaml` defines the namespace-owned `SecretStore`
`secret-lab-eso/vault`. ESO may request a token only for that namespace's
`vault-auth` SA via the accompanying Role/RoleBinding. Vault role `eso` may read
only `secret-lab/{data,metadata}/eso/*`. CA trust is the local public `vault-ca`
ConfigMap, restored by `prepare-local.sh`.

Working example (`components/secret-example-eso/secret.yaml`):

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: eso-example
  namespace: secret-lab-eso
spec:
  refreshInterval: 30s
  secretStoreRef: {kind: SecretStore, name: vault}
  target: {name: eso-example, creationPolicy: Owner, deletionPolicy: Retain}
  data:
    - secretKey: message
      remoteRef: {key: eso/example, property: message}
```

```bash
kubectl --context kind-local-dind-cluster -n secret-lab-eso get secretstore,externalsecret
kubectl --context kind-local-dind-cluster -n secret-lab-eso describe externalsecret eso-example
kubectl --context kind-local-dind-cluster -n secret-lab-eso annotate externalsecret eso-example \
  force-sync="$(date +%s)" --overwrite
kubectl --context kind-local-dind-cluster -n external-secrets logs deployment/external-secrets --tail=50
```

Use namespace-scoped stores by default. Store definitions and auth SAs belong to
the namespace owner. ClusterSecretStore/ClusterExternalSecret, push-secret and
cluster-generator controllers are disabled; enabling them is a separate trust
decision. Further providers get their own store/auth definition without replacing
the operator. Do not give tenants permission to edit another team's stores.
Generated Secrets are controller-owned; do not apply a competing Secret manifest.
Removing an ExternalSecret garbage-collects its owned Secret; removing a provider
value retains the last Kubernetes value and reports an error (`deletionPolicy:
Retain`). Read that status rather than treating an old value as proof of sync.

## VSO

`components/secret-stores/vso-vault.yaml` contains namespace-local `VaultConnection`
(TLS/CA), `VaultAuth` (Kubernetes role and SA). `VaultStaticSecret` selects a KV
path and destination. Vault role `vso` may read only its separate `vso/*` subtree.
The public CA is in `secret-lab-vso/vault-ca`; no Vault password/root token is in
the cluster. VSO's client token cache is memory-only; restart reauthenticates.

Working example (`components/secret-example-vso/secret.yaml`):

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: vso-example
  namespace: secret-lab-vso
spec:
  vaultAuthRef: vault
  type: kv-v2
  mount: secret-lab
  path: vso/example
  refreshAfter: 30s
  hmacSecretData: true
  destination: {create: true, overwrite: false, name: vso-example}
  rolloutRestartTargets:
    - {kind: Deployment, name: consumer}
```

```bash
kubectl --context kind-local-dind-cluster -n secret-lab-vso get vaultconnection,vaultauth,vaultstaticsecret
kubectl --context kind-local-dind-cluster -n secret-lab-vso describe vaultstaticsecret vso-example
kubectl --context kind-local-dind-cluster -n vault-secrets-operator \
  logs deployment/vault-secrets-operator-controller-manager -c manager --tail=50
```

Write a new Vault version to trigger the next refresh. VSO updates its own Secret
and restarts the example Deployment; it never owns ESO's or Sealed Secrets' Secret.

## Rebuild and recovery

For **the same host/environment**, retain these three things: the complete private
custody directory, `data-pool-1/vault-data`, and the existing mkcert CA (normally
under `mkcert -CAROOT`). The kind stop script retains the pools; `.local` is outside
the nodes. Do not delete either directory when deleting the cluster.

```bash
./scripts/cluster-setup/kind/start.sh
# Requires the existing GitHub bootstrap credential; restores CA and keyring first.
./scripts/flux/bootstrap.sh
# Wait for the Vault container to be Running (sealed/unready is expected), then:
kubectl --context kind-local-dind-cluster -n vault wait pod/vault-0 \
  --for=jsonpath='{.status.phase}'=Running --timeout=10m
./scripts/secrets/vault.sh bootstrap
./scripts/secrets/vault.sh login
./scripts/secrets/validate.sh
```

Retained Raft state includes KV values, auth methods, policies and passwords.
Fresh bootstrap imports the same sealing keys, restores public CA trust, and
unseals Vault with the matching key. It does not overwrite existing example values.
Missing keys or an empty Vault paired with old init material cause a hard stop.
Recover the missing state instead of generating a second key/store silently.

Ordinary Vault pod restarts also require manual unseal:

```bash
kubectl --context kind-local-dind-cluster -n vault delete pod vault-0
# Wait for the replacement container to start, then:
./scripts/secrets/vault.sh unseal
./scripts/secrets/validate.sh
```

Vault readiness remains false while Vault is sealed. There is deliberately no
liveness probe: a restarted Vault is a sealed one, so a probe could only turn a
stall, such as a laptop sleep, into a manual unseal. Single-member Raft cannot
tolerate loss of its sole data copy. Retained storage is not a backup:

```bash
./scripts/secrets/sealed-key.sh backup
./scripts/secrets/vault.sh snapshot
# Back up .local/secret-management/dev-cluster/ plus the mkcert CA with your
# encrypted backup tool to a separate disk. Never add either to Git.
```

If the Vault data directory is lost, recover the matching custody directory and
Raft snapshot. Restore onto a **fresh empty Vault** using temporary initialization
credentials, `vault operator raft snapshot restore -force <snapshot>`, restart,
then unseal with the **snapshot's original** key. This is a separate disaster
recovery operation; do not run `-force` against the retained live store. The normal
rebuild above avoids this by retaining the host PV. See `VALIDATION.md` for exactly
which recovery exercises were performed.

To deliberately prove controller/key restoration without deleting the cluster:

```bash
./scripts/secrets/recover-sealed.sh --simulate-key-loss
./scripts/secrets/validate.sh
./scripts/secrets/validate-auth.sh
```

The drill backs up all keys, suspends reconciliation, stops the controller, removes
its in-cluster keys, restores from disk, restarts, and forces fresh decryption of
unchanged ciphertext. It does not destroy Vault or unrelated workloads.

## Monitoring, upgrades and limits

The existing Prometheus discovers labeled ServiceMonitors for all components.
Vault metrics are readable without a token over TLS; they contain operational
metrics, not KV values. The local ingress is loopback-accessible. VSO metrics use
verified cert-manager TLS plus Kubernetes bearer-token authorization, replacing
the chart's insecure verification default. Audit events go to Vault stdout with
Vault's default sensitive-field HMAC, available through existing cluster logging.

All charts/images are version-pinned. Flux handles CRD creation/replacement;
VSO's duplicate CRD-upgrade hook is disabled. Review upstream CRD changes before
bumping, back up keys and take a Raft snapshot, render overlays/charts, reconcile,
then repeat validation. Do not uninstall CRDs as an upgrade technique. Vault uses
the chart's `OnDelete` update strategy: after an upgrade, deliberately restart and
unseal the pod. Restart Vault after certificate renewal so its listener reloads
the new certificate; inspect `kubectl -n vault get certificate` before expiry.

Vault's local hostPath needs an init container that can set ownership on **only
its mounted data directory**. This exception is confined to the dev overlay;
production CSI storage should supply correct ownership. Server and operator
containers are non-root, drop capabilities and have read-only root filesystems.
Consumers have no mounted Kubernetes credentials.

The current kindnet CNI does not enforce NetworkPolicy. Namespace/SA/Vault policy
boundaries are exercised here; no network isolation is claimed. The operators
remain trusted cluster controllers with Secret access. Production readiness also
requires enforced network policy, Kubernetes etcd encryption, external identity,
HA/custody and backup policy appropriate to that environment; those are outside
this local preparation and are not a mechanism recommendation.

Upstream references: [Sealed Secrets custom keys](https://github.com/bitnami/sealed-secrets/blob/main/docs/bring-your-own-certificates.md),
[ESO Vault provider](https://external-secrets.io/latest/provider/hashicorp-vault/),
[Vault Helm TLS](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/helm/examples/ha-tls),
[VSO API](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/api-reference).
