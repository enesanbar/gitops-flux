# Secret-management operator guide

Run commands from the repository root. Target: `kind-local-dind-cluster` only.
It prepares the experiments; it does not choose a mechanism.

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
Only explicit `bootstrap`, `snapshot` and the `tenant-auth` experiment helper use root. This local single-custodian
setup uses one key/share; it does not pretend to offer multi-person custody.
Production needs an independently chosen HA, seal/KMS, identity and custody plan.
Never copy these development credentials into another environment.

Policies are reviewed files in `scripts/secrets/vault/policies/`. Re-run
`vault.sh bootstrap` to apply a deliberate policy/role change. Kubernetes auth
uses Vault's projected service-account token as the TokenReview identity, with
the chart's `system:auth-delegator` binding. Client tokens use audience `vault`,
specific namespace/SA bindings, 10-minute TTL and 1-hour maximum. Vault refreshes
its own projected reviewer token; no long-lived Kubernetes reviewer Secret exists in this
cluster. The external-tenant experiment (`vault.sh tenant-auth`, see
`scripts/secrets/experiments/README.md`) is the documented exception: a Vault outside a cluster has
no identity that cluster accepts for TokenReview, so the tenant issues a long-lived reviewer token
that Vault holds for as long as the experiment's mount exists.

## ESO

`components/secret-stores/eso-vault.yaml` defines the namespace-owned `SecretStore`
`secret-lab-eso/vault`. ESO may request a token only for that namespace's
`vault-auth` SA via the accompanying Role/RoleBinding. Vault role `eso` may read
only `secret-lab/{data,metadata}/eso/*`. CA trust is the local public `vault-ca`
ConfigMap, restored by `prepare-local.sh`.

`components/trellis-secrets/` applies the same shape to an application namespace: `SecretStore`
`trellis/vault` with Vault role `trellis` (policy `secret-lab-trellis`, read-only on
`secret-lab/{data,metadata}/trellis/*`), a `vault-ca` ConfigMap that `prepare-local.sh` restores
there too, and two ExternalSecrets annotated never to be pruned, because `creationPolicy: Owner`
would garbage-collect the running application's Secret along with a pruned ExternalSecret
(`deletionPolicy: Retain` only covers a vanished backend entry). Role `trellis-app` (policy
`secret-lab-trellis-app`, the key-encryption-key entry only) is bound to the application's own
ServiceAccount for the command-based key-source experiment under
`scripts/secrets/experiments/kek-command/`.

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

Use a namespaced store where each namespace has an identity of its own, and the one
`ClusterSecretStore` where the cluster is handed a single credential (CONVENTIONS.md §2). The
`ClusterSecretStore` reconciler is on for that reason; the `ClusterExternalSecret` and push-secret
reconcilers are off and cluster generators get no RBAC, and enabling any of them is a separate
trust decision. Store definitions and auth SAs belong to the namespace owner. Further providers get
their own store/auth definition without replacing the operator. Do not give tenants permission to edit another team's stores.
Generated Secrets are controller-owned; do not apply a competing Secret manifest.
Removing an ExternalSecret garbage-collects its owned Secret; removing a provider
value retains the last Kubernetes value and reports an error (`deletionPolicy:
Retain`). Read that status rather than treating an old value as proof of sync.

## ESO: onboarding an application, rotating, and reading the failure

The conventions behind this section — path layouts, store scoping, ownership, and which features to
standardize — are in [CONVENTIONS.md](CONVENTIONS.md). `components/trellis-secrets/` is the worked
example; everything below is what you actually type.

### Onboarding an application

Four objects, in this order. `<app>` is both the namespace and the path segment.

1. **A Vault policy and role for the application**, committed rather than typed. The policy reads
   one subtree and nothing else; the role binds it to one ServiceAccount in one namespace, with an
   audience. The operator login cannot write either, so both go through `vault.sh bootstrap`, which
   applies what the repository holds and is safe to re-run. The three `auth/token` lines match every
   store policy already in `scripts/secrets/vault/policies/`: the roles there are created without
   Vault's default policy, so a store's token can only look itself up, renew and revoke if the
   policy says so.

   ```bash
   cat > scripts/secrets/vault/policies/<app>.hcl <<'HCL'
   path "secret-lab/data/<app>/*"     { capabilities = ["read"] }
   path "secret-lab/metadata/<app>/*" { capabilities = ["read", "list"] }
   path "auth/token/lookup-self" { capabilities = ["read"] }
   path "auth/token/renew-self"  { capabilities = ["update"] }
   path "auth/token/revoke-self" { capabilities = ["update"] }
   HCL
   # In vault.sh bootstrap, add <app> to the policy loop, and <app>:<app>:vault-auth:secret-lab-<app>
   # to the application-role loop (<role>:<namespace>:<service account>:<policy>). Then:
   ./scripts/secrets/vault.sh bootstrap
   ```

2. **The identity, in the application's namespace**: a ServiceAccount no pod mounts, and a Role
   letting the operator mint a token for that one ServiceAccount. It belongs in the application's
   component beside its store, so copy `components/trellis-secrets/rbac.yaml` there and change the
   namespace.

   `resourceNames: [vault-auth]` is what narrows the grant to one ServiceAccount — **but only while
   the operator holds no wider grant of its own.** Check before relying on it:

   ```bash
   kubectl --context kind-local-dind-cluster auth can-i create serviceaccounts --subresource=token \
     -n kube-system --as=system:serviceaccount:external-secrets:external-secrets
   ```

   `no` means token *requests* are limited to the ServiceAccounts the Roles name. `yes` means the
   chart grants them everywhere and the Role adds nothing: charts before 2.5.0 do so unconditionally,
   and from 2.5.0 `rbac.serviceAccountTokenCreate` controls it and defaults to `true`. Either way the
   operator stays one of the most privileged identities on the cluster — it creates and reads Secrets
   wherever it delivers — and CONVENTIONS.md §2 says what that means and what to do about it.
   (`kubectl auth can-i` exits non-zero when the answer is `no`; read the answer, not the exit
   status.)

3. **The CA the store trusts**, as a ConfigMap: a public certificate, not a secret, but specific
   to this machine, so `scripts/secrets/prepare-local.sh` creates it rather than Git. That script only
   knows the namespaces it lists: add `<app>` to both lists (the namespaces it creates, and the ones
   it writes `vault-ca` into), then re-run it. It also restores the Sealed Secrets key, so it is a
   bootstrap step, not a ConfigMap helper.

4. **The store and the ExternalSecret**, copied from `components/trellis-secrets/` with the
   namespace, role and paths changed, in a component wired the way every component here is: the
   component under `components/`, a shim under `clusters/dev-cluster/components/`, and its Flux
   `Kustomization` registered in that tree's `flux-system/kustomize/`. Give the component a
   `Namespace` manifest if nothing else creates the namespace. Once Flux has applied it:

   ```bash
   kubectl --context kind-local-dind-cluster -n <app> get secretstore,externalsecret
   kubectl --context kind-local-dind-cluster -n <app> get externalsecret <name> \
     -o jsonpath='{.status.conditions[0].reason}{"  "}{.status.conditions[0].message}{"\n"}'
   ```

   Read key **names and lengths** when you verify, never values:

   ```bash
   kubectl --context kind-local-dind-cluster -n <app> get secret <name> \
     -o go-template='{{range $k,$v := .data}}{{$k}} ({{len $v}}){{"\n"}}{{end}}'
   ```

   Printing a Secret's `metadata.annotations` is as bad as printing its `data`: a Secret that was
   ever applied with `kubectl apply` carries the whole object, values included, in
   `last-applied-configuration`.

### Onboarding an application on a delivered credential

A cluster that is handed one credential has one store, `components/aws-parameterstore/`, so there
is no identity or role per application: onboarding is one edit, some writes and a copy.
`components/ssm-app-secrets/` is the worked example. In this lab the AWS side comes first, run by
the account owner in this order: `scripts/secrets/experiments/aws/base-iam.sh` (the experiment user,
its reader role and the KMS key, with the user's one access key written to a 0600 file),
`scripts/secrets/aws-credentials.sh import` (that key into custody), then
`scripts/secrets/experiments/aws/tenant-iam.sh apply`, which lets the lab user write the realm and
writes the stand-in's two keys to custody. `scripts/secrets/aws-credentials.sh tenant a` then puts
the stand-in credential where a platform would.

1. **List the namespace on the store**: add it to `spec.conditions[0].namespaces` in
   `components/aws-parameterstore/cluster-secret-store.yaml`. An `ExternalSecret` in an unlisted
   namespace fails, and its events say `using cluster store "aws-parameterstore" is not allowed from
   namespace "<ns>": denied by spec.condition`. The list decides **which namespaces** may use the
   store and nothing about **which paths** they read. Hold each `ExternalSecret` to its own subtree
   in review and CI: every `spec.data[].remoteRef.key` and `spec.dataFrom[].extract.key` begins with
   `/devops/<cluster>/<its own namespace>/` or is on a named list of exceptions (the certificate
   another team keeps is one), and no `dataFrom.find` uses the store. CI sees only what comes through
   Git; for an `ExternalSecret` created through the API, RBAC on `externalsecrets` in the listed
   namespaces is the boundary (CONVENTIONS.md §2).

2. **Write the values** under `/devops/<cluster>/<namespace>/` with `scripts/secrets/ssm.sh`. It takes
   the value on standard input, always writes an Advanced SecureString under the lab's KMS key, and
   refuses a path outside the layout, a path that is already a folder, and a write with no description:

   ```bash
   export SECRET_STATE_DIR=/path/to/gitops-flux/.local/secret-management/dev-cluster
   openssl rand -hex 32 | ./scripts/secrets/ssm.sh put /devops/dev-cluster/<app>/service_token \
     --description "Service token. Generated here; rotate by writing a new version, then roll the consumer."
   openssl rand -base64 32 | ./scripts/secrets/ssm.sh put /devops/dev-cluster/<app>/encryption_key --key-class \
     --description "Encryption key. Rotates only through the application's re-wrap; consumers pin a version."
   { printf 'app_user\n'; openssl rand -hex 16; } | jq -Rsc 'split("\n") | {username: .[0], password: .[1]}' | \
     ./scripts/secrets/ssm.sh put /devops/dev-cluster/<app>/database --description "Database account, one JSON object."
   ./scripts/secrets/ssm.sh list /devops/dev-cluster/<app>
   ```

   `put` strips one trailing newline, because `openssl` and `jq` both end with one; `--exact` keeps
   the bytes as they are, which is what a PEM file wants. A credential whose fields change together
   is one JSON parameter, read with one `dataFrom.extract`, so a rotation arrives in one sync.

3. **The Namespace and the ExternalSecrets**, copied from `components/ssm-app-secrets/` with the
   namespace, paths and key names changed, in a component wired the usual three places, its Flux
   `Kustomization` depending on `aws-parameterstore` and carrying the `healthCheckExprs` of
   `ssm-app-secrets`: without them Flux reads an `ExternalSecret` with no status yet, or a stale Ready
   after a spec change, as healthy. Copy the expression whole: it skips the generation check for
   `CreatedOnce`, and for `Periodic` with a zero interval, which never sync again once synced and
   would otherwise hold the group back for good after their first spec edit. Verify the store, then each `ExternalSecret`'s
   condition and events, then key names and lengths:

   ```bash
   kubectl --context kind-local-dind-cluster get clustersecretstore aws-parameterstore
   kubectl --context kind-local-dind-cluster -n <app> get externalsecret
   kubectl --context kind-local-dind-cluster -n <app> describe externalsecret <name>   # Events: the cause
   ```

An application moving to another cluster takes its subtree with it. Copy it, never regenerate it:
a restored database only opens under the key it was written with. `copy-tree` replays each
parameter's versions in order, labels included, so the pins in the moved manifests name the same
bytes. It checks every history before writing anything and copies nothing if one no longer starts
at version 1; an AWS error part-way leaves what it wrote, to delete before retrying. The copy carries
every superseded value too, a leaked one included: when an old version must not travel, write the
current values under the new prefix with `put` and move the pins to the new numbers instead.

```bash
./scripts/secrets/ssm.sh copy-tree /devops/<old-cluster>/<app> /devops/<new-cluster>/<app>
```

### Rotating a value

Write the new version in the backend; nothing in the cluster needs touching.

```bash
openssl rand -base64 32 | tr -d '\n' | \
  ./scripts/secrets/vault.sh cli kv put -mount=secret-lab <app>/<entry> KEY=-
```

`KEY=-` reads the value from standard input, so it never reaches the process list or shell history.
`tr -d '\n'` is not decoration: `openssl` and `jq -r` both append a newline, and that newline is
delivered into the Secret and into whatever reads it. `kv put` **replaces the whole entry** — any
other field in it is gone afterwards — so to change one field of several, use `kv patch`.

On Parameter Store a new value is a new version of the parameter, and `ssm.sh` asks for `--overwrite`
so it is never an accident:

```bash
openssl rand -hex 32 | ./scripts/secrets/ssm.sh put /devops/dev-cluster/<app>/service_token --overwrite \
  --description "Service token. Generated here; rotate by writing a new version, then roll the consumer."
```

A parameter tagged as a key refuses even that without `--new-key-version`, and a new key version
reaches nothing until the commit that moves its consumers' pins.

The Secret follows within the refresh interval. To stop waiting:

```bash
kubectl --context kind-local-dind-cluster -n <app> annotate externalsecret <name> \
  force-sync="$(date +%s)" --overwrite
```

**The process does not follow.** An environment variable is fixed at container start, and a file
mounted with `subPath` is never updated in place — only a whole-volume mount is refreshed, and even
then the process must re-read the file. Plan the rollout:

```bash
kubectl --context kind-local-dind-cluster -n <app> rollout restart deployment/<name>
```

or adopt the reloader below and accept what it costs.

### The key class

An encryption or signing key is not a credential: losing it loses data. Deliver it with its own
`ExternalSecret`, its own Secret, `refreshPolicy: CreatedOnce` and `deletionPolicy: Retain` — or,
when the chart takes it in one Secret with the credentials, as `components/trellis-secrets/` does,
pin its backend version with `remoteRef.version` so only a reviewed commit can move it. Never behind
anything that can generate a value. Rotation is a re-encryption with both keys present, never a
value swap. CONVENTIONS.md §4 has the full rule and the pin's own hazards.

### Reading the failure

Read the `ExternalSecret`, then its events. Its condition says **whether** the last sync failed; the
message only narrows it — any failure to read from the backend reads `could not get secret data from
provider`, a failure to write the Secret (a bad template, for one) reads `could not update secret` —
and the cause itself is in the events and the controller log.

```bash
kubectl --context kind-local-dind-cluster -n <app> get externalsecret -o custom-columns=\
'NAME:.metadata.name,REASON:.status.conditions[0].reason,REFRESHED:.status.refreshTime'
kubectl --context kind-local-dind-cluster -n <app> describe externalsecret <name>   # Events: the cause
kubectl --context kind-local-dind-cluster -n external-secrets logs deployment/external-secrets --tail=50
```

**Do not read the `SecretStore`'s condition as the backend's state.** It is the result of the store's
own validation, which runs on its own schedule and checks only whether a login works. With Vault
sealed, one run here caught it and turned the store `InvalidProviderConfig` within a second; another
saw the store stay `Valid` for the whole outage. Through every failure after login — a revoked
policy, a deleted entry, credentials that expired downstream — and through an unreachable Parameter
Store endpoint, it stayed `Valid` every time. A `Valid` store proves nothing about the backend; on
a store that logs in, as the Vault stores do, an `InvalidProviderConfig` one is a real login failure.

| What you see | What it means | What to do |
| --- | --- | --- |
| `SecretSynced` | The last sync succeeded. It does **not** mean the value is current: under `deletionPolicy: Retain` a Secret keeps its last good value while syncs fail, so check `REFRESHED`. | Nothing. |
| `SecretSyncedError` (store `Valid` or not) | A sync failed. **This is the common shape of every outage**, because the store often has not noticed yet. The event says which: `Secret does not exist` for a missing entry or a mistyped path (the two read the same, for Vault and Parameter Store alike, and never as Parameter Store's own `ParameterNotFound`); `permission denied` when a Vault policy does not cover the path; an access denial with a request id; an expired token; a refused or timed-out connection when the backend is down; a sealed-Vault error from the login. | Follow the event. For a backend error, check the backend's health before anything in the cluster. For a path, compare `remoteRef.key` with a listing of its parent. Never delete the ExternalSecret to "reset" it: that garbage-collects the Secret. |
| store `InvalidProviderConfig` (a store that logs in, such as Vault's) | The store's last login failed: the backend is sealed or unreachable, or the store's CA, server, auth mount or role is wrong. | The backend's health **first**, the store definition second. |
| `SecretDeleted`, and the Secret is gone | `deletionPolicy: Delete` met a backend that answered "not found". | Restore the entry, then change the policy to `Retain`. |
| An `ExternalSecret` stuck in `Terminating` | It carries the operator's cleanup finalizer (0.20.3 and 2.11.0 both add it) and the operator is not running, so the deletion waits; a Flux prune of it, or of its namespace, waits the same way. | Bring the operator back and it finishes the deletion, its Secret going with it. Do not strip the finalizer. |

On a store that reads a delivered credential the condition means even less: for a static key the
store's validation only resolves the credential it was given and makes no call to AWS, and it notices
a missing credential Secret only when it next validates (every five minutes, by the operator's
defaults). Five shapes of their own:

| What you see | What it means | What to do |
| --- | --- | --- |
| `SecretSyncedError`, events `UnrecognizedClientException: The security token included in the request is invalid`, store `Valid` | The delivered key is dead: rotated away, revoked or deleted. A revocation took 36 and 194 seconds to bite in two runs here, while IAM propagated it; neither is a bound. | Ask the platform what happened to the credential, and check when the delivered Secret last changed. Nothing in this repository fixes it. |
| `SecretSyncedError`, events `could not fetch SecretAccessKey secret: cannot get Kubernetes secret "aws-credentials" …`, store `Valid` | The credential Secret is missing, and the store has not validated since. | The platform's delivery first; once it is back, validate and sync as in the next row. |
| store `InvalidProviderConfig`, events `ClusterSecretStore "<name>" is not ready` | The store's validation found the credential Secret missing or incomplete. Every `ExternalSecret` on the store then fails until it validates again, and failed ones retry on a backoff of up to seven minutes. | Restore the delivery, then validate the store and force-sync rather than wait: `kubectl --context kind-local-dind-cluster annotate clustersecretstore aws-parameterstore force-validate="$(date +%s)" --overwrite`, then the force-sync under "Rotating a value". Delivered Secrets keep their last values meanwhile. |
| events `… is not allowed from namespace "<ns>": denied by spec.condition` | The namespace is not on the store's list. | Onboarding step 1 above. |
| `SecretOwnedByOther`, message `target is owned by another ExternalSecret: …` (on operator 0.20.3: reason `SecretSyncedError`, message `target is owned by another ExternalSecret`, the owner named only in the event) | A second `ExternalSecret` targets a Secret another one owns — usually a rename under `prune: disabled`, which leaves the old one serving it. | Delete the old `ExternalSecret` on purpose, then force-sync the new one. The Secret is absent in between, because the deletion garbage-collects it. For a key-class Secret, first pin the new `ExternalSecret` to the version the old Secret holds: a `CreatedOnce` one would otherwise take the backend's latest. |

### Restarting on change: what a reloader costs

`components/reloader/` closes the gap between "the Secret changed" and "the process sees it": it
watches Secrets and restarts the Deployments that consume them. Measured end to end, a backend write
reached the running process in 59 seconds on a one-minute refresh interval — the reloader reacts to
the Secret changing, so the interval dominates. A refresh that changes nothing restarts nothing.
Three things come with it, and they are the reason it is opt-in rather than default:

- It needs **get/list/watch on Secrets cluster-wide**. That is a controller that can read every
  Secret in the cluster, so it is a trust decision, not a convenience.
- Every consumer of a changed Secret restarts. A Secret shared by several workloads becomes a
  fan-out restart, which is exactly when you least want one.
- It leaves a **content digest of the Secret readable on the Deployment**: the pod-template
  annotation `reloader.stakater.com/last-reloaded-from` carries a 40-character `hash` field. Switching the reload strategy
  moves that fingerprint; it cannot remove it, because detecting that content changed is the
  mechanism. A workload whose key must not be fingerprinted at all cannot use a reloader.

Scope it with `namespaceSelector` and decide per namespace.

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
