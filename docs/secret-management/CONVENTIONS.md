# Conventions for delivering secrets with the External Secrets Operator

What follows is what the experiments in this repository settled, stated as rules with the reason
attached. Each rule says which kind it is: **Measured** names the script under
`scripts/secrets/experiments/` that observed it, and **Judgement** marks a design call that no
experiment can settle. Which operator version a measurement covers follows from the script: the
parity checks (`parity/parity-checks.sh`, check ids P0–P6 and the token-minting check) ran with the
same script against ESO 2.11.0 and 0.20.3; `parity/ssm-parity.sh` replays the delivered-credential
store of §2 on 0.20.3 against the parameters the lab reads; the rows under `matrix/` ran on the
lab's 2.11.0 only.

The scope is **delivery**: getting a value that lives in an external store into a Kubernetes Secret,
and from there into a process. Issuance (minting a certificate, creating a database user) is a
different problem and is called out where the two are easy to confuse.

## 1. Where secrets live in the backend

### The rule

**Judgement** — no experiment measures a naming scheme; the criteria are the ones the table scores.

Put in the path only what is **stable** and what a **policy has to cut on**. Everything else —
owning team, ticket, cost centre, who asked for it — belongs in metadata, because a path is an
identifier that consumers hard-code and metadata is not.

What qualifies follows from where the identity sits. With a Vault identity per namespace, two things:
the **environment** (a policy boundary, an account boundary, and the thing you must never let leak
across) and the **application** (the unit that owns, rotates and loses a secret). With a credential
delivered per cluster, the **cluster** and the **namespace** take those two places, for the same two
reasons (the Parameter Store layout below). A team does not qualify — teams reorganize, and every
rename breaks every consumer — except as the one prefix that separates teams sharing an account: a
realm names the owner of part of the account, not a line on an org chart.

### Vault (KV v2)

**Recommended:** one KV mount per environment, and `<application>/<purpose>` inside it.

```
kv-prod/  billing-api/db          -> { username, password }
          billing-api/signing-key -> { SIGNING_KEY }
          billing-api/tls         -> { tls.crt, tls.key }
kv-stage/ billing-api/db          -> { username, password }
```

The environment is a **mount**, not a path prefix, because a mount is the strongest boundary Vault
offers: policies, audit devices and even a seal can differ per mount, and no policy typo can widen a
path glob across it. An entry holds the fields that are replaced together — a username and its
password are one account, so they are one entry, read with `dataFrom.extract`.

The alternative, `<environment>/<team>/<application>/<purpose>` in a single mount, was rejected:
the team segment is the unstable one, and a single mount means one policy mistake spans production
and staging.

### How the two Vault shapes score

| Criterion | Environment-mount + `app/purpose` | `env/team/app/purpose`, one mount |
| --- | --- | --- |
| Readability | Short. The mount answers "which environment" before you read the path. | Long, and the team segment adds a word nobody reads. |
| Ownership | The application segment is the owner. | Two segments claim ownership and can disagree after a reorg. |
| Policy boundaries | Mount-level; a path glob cannot escape it. | Every boundary is a path glob in one namespace of paths. |
| Environment isolation | Structural. | By convention only. |
| Discoverability | `vault kv list kv-prod/` enumerates applications. | Listing requires knowing the team first. |
| Migration | An application moves by copying one subtree. | A team rename rewrites every path under it. |
| Automation | Path derives from two facts a pipeline already has. | Needs a team lookup. |
| Multi-cluster | Clusters in one environment share a mount; nothing to template. | Same, but the extra segment must be templated too. |
| Simplicity | Two segments. | Four. |

The one thing the rejected shape does better is answering "what does my team own" — which is a
question for an inventory, not for a path.

### AWS Systems Manager Parameter Store, on a delivered credential

**Recommended:** `/<realm>/<cluster>/<namespace>/<any nesting>/<name>`, one value per parameter.

```
/devops/staging-cluster-a/billing/encryption_key
/devops/staging-cluster-a/billing/database                -> {"username": "…", "password": "…"}
/devops/staging-cluster-a/billing/worker/broker/password
/devops/production-cluster-a/billing/encryption_key
```

- **The realm** (`/devops/`) is one team's prefix in an account several teams share: an
  organisational boundary, and a security one only if the credential's policy makes it so. Material
  another team owns stays under that team's realm and is read from there, never copied into yours.
- **The cluster comes first**, because it is the unit of identity: a platform that hands each cluster
  its own credential can scope that credential to `/<realm>/<cluster>/*`, and a layout that starts
  anywhere else leaves such a policy nothing to cut on. The environment is not lost as long as cluster
  names begin with it: `/<realm>/production-*` still selects every production cluster.
- **The namespace comes next**, because an `ExternalSecret` already carries it: review and CI can hold
  every `ExternalSecret` to `/<realm>/<cluster>/<its own namespace>/` and name each exception (§2).
- **Below the namespace, nest freely** — a component, then whatever grouping its owner chooses — with
  one rule, which `scripts/secrets/ssm.sh` enforces: **a node is a parameter or a folder, never both**.
  Otherwise `…/db` and `…/db/password` coexist and two readers disagree about which is the credential.
- **The name is snake_case**, so that it can serve unchanged as the `secretKey` and as a template
  variable: `{{ .service_token }}` parses and `{{ .service-token }}` does not. A JSON parameter's fields
  follow the same rule, because `dataFrom.extract` turns them into template variables. The segments
  above the name are Kubernetes names, so kebab-case.
- **Fields that change together are one parameter holding a JSON object**, read with one
  `dataFrom.extract` (§5). **Measured** on 2.11.0 (`matrix/r-tenant-store.sh` row B): one write
  reached the Secret in one sync with both fields changed, and the same on 0.20.3
  (`parity/ssm-parity.sh`); the controller reads the parameter once on both versions (read in its
  source). As two parameters it would be two writes, and a refresh landing between them
  delivers a new username beside an old password for a whole interval.
- **Nothing is shared across clusters until something must be.** Then it gets a first segment of its
  own where the cluster would go (`/<realm>/shared-<scope>/<namespace>/…`), each reader names it as an
  exception, and nothing already written has to move.
- **An application that changes cluster copies its subtree** (`ssm.sh copy-tree`) and never
  regenerates it: a key follows the data it encrypts, not the cluster it runs on. A pin names a
  version *number*, so the copy replays each parameter's history in order and the pins in the moved
  manifests name the same bytes; it refuses a parameter whose history no longer starts at version 1.

`ssm.sh` writes every parameter as an Advanced SecureString under one customer-managed key: Advanced
because a certificate chain can pass the standard tier's 4 KB, and one key the store's credential may
use through Parameter Store only.

The environment-first alternative, `/<environment>/<application>/<name>`, puts the environment where
the identity is not: on a credential delivered per cluster, an environment folder mixes the secrets of
every cluster in that environment, whatever runs on them, and no per-cluster policy could be written
against it.

## 2. The store follows the identity

**Rule: one store per identity** (**Judgement**, resting on the measurements below). Where each
namespace can have an identity of its own — Vault's
Kubernetes auth with a token minted per namespace — a `SecretStore` in the application's namespace.
Where the cluster is handed one credential it did not create, one `ClusterSecretStore` reading it,
limited to the namespaces it names.

### A namespace with an identity of its own

A namespaced store authenticates as **that namespace's** ServiceAccount, so the backend policy can
be written per application and the audit trail names the application. A cluster-scoped store over the
same backend would authenticate once, for everybody: the backend would see one identity reading
everything, and the only boundary left would be Kubernetes RBAC on who may create an
`ExternalSecret` — easy to widen by accident, and invisible from the backend side.

The identity is a short-lived token minted through the TokenRequest API with an audience, never a
ServiceAccount token Secret mounted into a pod. Grant the operator `create` on
`serviceaccounts/token` for **that one ServiceAccount by name** (`resourceNames`), which is what
`components/trellis-secrets/rbac.yaml` does.

### A cluster with one delivered credential

A platform that hands a cluster one cloud credential — a Secret it writes into the operator's
namespace and rotates there — gives every application on the cluster the same identity at the
backend. A store per namespace would copy that credential into every namespace and gain nothing, since
the backend would still see one caller. So one `ClusterSecretStore` reads it
(`components/aws-parameterstore/`), and four things hold for it:

- **The namespace list is all the store enforces.** **Measured** (`matrix/r-tenant-store.sh` row C;
  the same wording on 0.20.3 in `parity/ssm-parity.sh`): an `ExternalSecret` in an unlisted namespace
  is refused, and only its events say why — `… is not allowed from namespace "<ns>": denied by
  spec.condition`.
- **It does not scope paths.** **Measured** (row C): an `ExternalSecret` in a listed namespace read a
  path belonging to another namespace within seconds. Which keys each `ExternalSecret` may read is
  therefore a rule for review and CI — every `data[].remoteRef.key` and `dataFrom[].extract.key` in
  its own subtree, plus a named list of exceptions such as a certificate another team keeps, and no
  `dataFrom.find` — and CI sees only what comes through Git. For an object created through the API,
  RBAC on `externalsecrets` in the listed namespaces is the boundary; an admission policy comparing
  each key with the object's namespace is the one in-cluster enforcement (**Judgement**, not
  exercised). A credential that can write also lets a `PushSecret` write through the store anywhere the
  credential reaches, which is one more reason its reconciler stays off here; the chart's defaults
  turn the `PushSecret` and `ClusterPushSecret` reconcilers on (read in its values, 0.20.3 and
  2.11.0), so a cluster that runs them as shipped has that path open.
- **Its condition says nothing about the backend.** For a static key the operator's validation only
  resolves the credential it was given and calls nothing (read in the provider's `Validate()`, 0.20.3
  and 2.11.0). **Measured** (rows D and F): the store read `Valid` while syncs failed with
  `UnrecognizedClientException`, both with a key AWS does not know and with the key in use revoked.
  With the credential Secret removed it kept reading `Valid` until its next validation, while syncs
  failed on `could not fetch SecretAccessKey secret`; after a validation (forced here, every five
  minutes by default) it read `InvalidProviderConfig`, and `ExternalSecret`s failed with
  `ClusterSecretStore "<name>" is not ready`.
- **It reads the credential Secret on every sync**, so a platform's rotation needs nothing from the
  cluster. **Measured** (row D, and on 0.20.3 `parity/ssm-parity.sh`): with a key AWS does not know
  swapped in, the next sync failed; with the real key back, the next one succeeded — each within one
  five-second poll.

This repository turns the `ClusterSecretStore` reconciler on for that reason. `ClusterExternalSecret`
stays off (§5).

### What the operator can do, whatever its Roles say

**Measured** (`parity/parity-checks.sh`, the token-minting check; `parity/parity-gate.sh remedy`;
`matrix/r17-operator-token-secret.sh`).

The operator writes Secrets in every namespace it delivers to, so its chart gives it `secrets`
create, read, update and delete **cluster-wide**, on 0.20.3 and on 2.11.0 alike — that is the job,
not a mistake. The consequence is easy to miss: a `kubernetes.io/service-account-token` Secret the
operator creates for *any* ServiceAccount is filled in by the cluster's token controller, and the
operator can read it back. Measured on the lab with the TokenRequest grant already removed: it
obtained a long-lived token for a ServiceAccount no Role names. **A compromised or misconfigured
operator can act as any ServiceAccount on the cluster.** Treat its identity as one of the most
privileged there is — who can change its image, its Deployment or its namespace is a question with
the same weight as who holds cluster-admin. This is the same class of reach as anything else that
writes Secrets cluster-wide, and not specific to this operator.

What the pieces of the setup above do and do not change:

| Control | What it closes | Measured |
| --- | --- | --- |
| A per-namespace Role granting token requests for one named ServiceAccount | Nothing on its own; it is what the store needs once the chart's wider grant is gone | the store depends on it once the wider grant is removed |
| No cluster-wide token-request grant (chart ≥ 2.5.0 with `rbac.serviceAccountTokenCreate: false`, or the patch below on older charts) | The TokenRequest door: short-lived tokens for arbitrary ServiceAccounts | yes, both ways |
| Both of the above together | Not the Secret door: a service-account-token Secret still yields any ServiceAccount's token | yes |

So removing the cluster-wide token grant is **hygiene worth the one line it costs**, not a bound on
the operator. What actually bounds it:

- **Scope it.** With `scopedNamespace` and `scopedRBAC`, the chart renders the controller's rules as a
  Role in that one namespace instead of a ClusterRole (checked by rendering 0.20.3). That fits an
  operator serving one namespace, not a shared one. Its certificate controller keeps cluster-wide
  read and update on Secrets either way, though not create.
- **Refuse the Secret door at admission** (**judgement**, not exercised here): an admission policy
  that denies the operator's ServiceAccount the creation of `kubernetes.io/service-account-token`
  Secrets closes the escalation path while leaving delivery alone.

The token-request grant, by chart version:

| Chart | Cluster-wide token requests | Asked of the operator's identity |
| --- | --- | --- |
| before 2.5.0 (0.20.3 measured) | granted; no dedicated switch — only scoping the whole operator (`scopedNamespace` + `scopedRBAC`) or `rbac.create: false` removes it | any ServiceAccount in `kube-system`: **yes**; a ServiceAccount no Role names: **yes** |
| 2.5.0 and later | `rbac.serviceAccountTokenCreate`, **default `true`** | as above until it is set to `false` |
| 2.11.0 with `rbac.serviceAccountTokenCreate: false` (this repository) | removed | `kube-system`: **no**; the named ServiceAccount: **yes**; any other: **no** |

Ask the cluster rather than reading chart versions:

```bash
kubectl auth can-i create serviceaccounts --subresource=token -n kube-system \
  --as=system:serviceaccount:external-secrets:external-secrets
```

Removing it, by chart version:

- **2.5.0 and later**: set `rbac.serviceAccountTokenCreate: false` in the operator's values, as
  `components/external-secrets/helm-release.yaml` does, and give a Role to every namespace where the
  operator must request a token — each namespace with a store, and each with a generator that names
  a ServiceAccount.
- **Before 2.5.0**: remove the rule after rendering. A Flux `HelmRelease` does it with a post-renderer
  carrying `scripts/secrets/experiments/parity/strip-token-rule.patch.yaml`:

  ```yaml
  spec:
    postRenderers:
    - kustomize:
        patches:
        - target: {kind: ClusterRole, name: external-secrets-controller}
          patch: |
            - op: test
              path: /rules/7/resources/0
              value: serviceaccounts/token
            - op: remove
              path: /rules/7
  ```

  The index is render-specific: the rule is at 7 in a 0.20.3 render with this repository's values
  and at 8 with the chart's defaults, because `processClusterExternalSecret: false` drops a rule above
  it. Derive it from your own render (`helm template` piped through `yq`). The `test` operation is
  what makes a wrong index safe — the render stops instead of removing a different rule — so a failed
  reconcile after a chart or values change means "re-derive the index", not "the patch is broken".
  Measured on 0.20.3: with the rule removed, the namespaced store keeps working on its Role alone, and
  removing that Role then breaks it. The patch operations were applied to the live ClusterRole and to
  chart renders; the `HelmRelease` wrapper itself was not run through Flux here.

Cluster-scoped is the right answer for two shapes: the delivered credential above, and material the
platform owns that is byte-identical in every namespace and whose reader identity genuinely is "the
cluster" — a private registry pull credential, for instance. Either way, prefer one `ExternalSecret`
per namespace over a `ClusterExternalSecret`, because a single object that writes into every namespace
is also a single object that can empty every namespace.

## 3. One authoritative manager per Secret

**Rule: every Kubernetes Secret has exactly one thing that creates and updates it, and you can name
that thing from the Secret alone.**

| Secret class | Its manager | Never |
| --- | --- | --- |
| Application credentials from an external store | An `ExternalSecret` with `creationPolicy: Owner` | A chart that also templates the same Secret |
| Certificates issued in-cluster | cert-manager's `Certificate` | An `ExternalSecret` pointing at the same name |
| Operator-internal credentials (database operators, brokers) | That operator | Anything else; the operator will reconcile you away (**judgement**, not measured here) |
| Chart-generated internals (cookies, admin passwords) | The chart | Moving them to the store for its own sake |

Two consequences, **measured** (`matrix/r12-key-class.sh`):

- **`creationPolicy: Owner` puts an owner reference on the Secret**, so deleting or renaming the
  `ExternalSecret` garbage-collects the running application's Secret. In a GitOps repository that
  makes a *pruning* event — a moved file, a renamed component — into an outage. Application
  `ExternalSecret`s therefore carry `kustomize.toolkit.fluxcd.io/prune: disabled`. `deletionPolicy:
  Retain` does not help here: it covers a vanished **backend** entry, not a vanished ExternalSecret.
  The price is drift: a renamed or removed `ExternalSecret` now stays in the cluster until someone
  deletes it by hand. That is the right trade — a stale object is visible, a missing Secret is an
  outage — but it is a trade, and a rename needs that manual step.
- **You cannot merge into a Secret somebody else owns.** `creationPolicy: Merge` against a Secret
  that already carries another owner is refused, which is the operator protecting the rule above.
  Plan for it: there is no "add one key to the chart's Secret" move.

## 4. Migrating an existing Secret without a window where two systems race

The transition below is the one that has no moment where two managers write the same object. It
costs one extra name and one extra rollout, and that is the price of never being ambiguous.

1. **Create a new Secret under a new name**, owned by an `ExternalSecret`. The old Secret is
   untouched and the application still reads it.
2. **Verify the new Secret** — key names, lengths, type — without repointing anything. For a value
   that cannot be regenerated (see below), verify it matches the old one *before* step 3, out of
   band; the delivery mechanism cannot tell you whether it delivered the right key, only that it
   delivered one.
3. **Repoint the consumer** at the new name and roll it out. This is the only step with a rollback,
   and the rollback is "point back at the old name", which still exists.
4. **Delete the old Secret and its previous manager** — the sealed manifest, the chart stanza, the
   hand-applied YAML. Until this step the repository still contains a second manager, so do not
   leave it undone.

**Never** migrate by repointing an `ExternalSecret` at the old Secret's name with `Merge` (step 3
would be refused, and if it were not, two managers would own one object), and never by deleting the
old Secret first (that is an outage with no rollback).

### The class that changes the order: keys that cannot be regenerated

An encryption or signing key — anything whose loss means the data is gone, not that a service is
briefly down — is not a credential and must not be treated like one. It has no issuer, so there is
nothing to revoke and nothing to reissue; rotation is a re-encryption or a re-wrap, never a value
swap.

For that class:

- Deliver it with its **own** `ExternalSecret` and its **own** Secret, not composed into an
  application blob with the credentials, so that its policy, its refresh and its blast radius are
  separate.
- Use `refreshPolicy: CreatedOnce`. The value must not change underneath a running process, because
  a process that re-reads it will decrypt nothing. **Measured** on both operator versions
  (`parity/parity-checks.sh` P2): a new backend version did not reach it through a forced sync that a
  Periodic object on the same interval followed.
- **When the consumer takes one Secret** — a chart with a single `existingSecret` for the key and its
  credentials — the key cannot have a Secret of its own, and `CreatedOnce` would freeze the
  credentials with it. Pin the key's backend version instead (`remoteRef.version`). **Measured** on
  both operator versions against Vault KV v2 (`parity/parity-checks.sh` P2, P3): a new version of the
  key reaches nothing, the pinned `ExternalSecret` stays healthy, and the other keys in the same
  Secret keep refreshing. Rotating the key is then a reviewed commit that moves one number, made as
  the last step of the re-encryption. `components/trellis-secrets/` is this case. Two hazards come
  with the pin. If the pinned version is destroyed — or pruned, because KV v2 keeps ten versions by
  default — the whole `ExternalSecret` fails, not just that key (one bad entry fails the whole object:
  **measured**, `matrix/r3-r4-paths-and-deletion.sh`); `Retain` keeps the Secret, but every other key
  in it stops refreshing. Raise the entry's `max_versions`, or re-pin, before that can happen. And the
  pin binds this operator only: anything reading the entry directly still gets the latest version.
- Use `deletionPolicy: Retain`, so a backend blip cannot remove the key from under a mounted volume.
- Never put it behind a generator, a chart `randAlphaNum` default, or anything else that can produce
  a *new* value when the old one is missing. Silent regeneration of a key is indistinguishable from
  total data loss, and it happens at the worst possible moment: when the backend is unreachable.
- Never put an **unpinned** key in a Secret a reloader watches: the reloader turns a backend write
  into a restart within the refresh interval, and the process comes up under a key that opens none
  of the data sealed with the old one. A pinned or `CreatedOnce` key is safe beside a reloader:
  **measured** on 2.11.0 (`matrix/r16-pinned-key-under-reloader.sh`), a new version of a pinned key refreshed
  the Secret without changing its bytes and restarted nothing, while a new version of an unpinned key
  in the same Secret restarted the consumer.

## 5. Operator features: what to standardize, and what to refuse

### Standardize

Rows whose evidence is a P-numbered check held on ESO 2.11.0 and 0.20.3 alike; rows citing
`matrix/` were measured on 2.11.0, "row A" to "row F" being `matrix/r-tenant-store.sh`;
`parity/ssm-parity.sh` covers the delivered-credential store on 0.20.3.

| Feature | Why | Evidence |
| --- | --- | --- |
| Explicit `data[]` mapping | The `ExternalSecret` states every key it produces, so a reviewer can see the Secret's shape without reading the backend, and a key that disappears upstream becomes an error rather than an absence. | **Measured**: a deleted entry turned the ExternalSecret `SecretSyncedError` while the Secret kept its key (P5). |
| `dataFrom.extract` for one entry | The right tool for a credential *pair*: a username and password replaced together are one entry — a Vault entry, or one Parameter Store parameter holding JSON — and it reads that entry once, where a `remoteRef.property` per field reads it once per field. | **Measured**: every field of one entry, and only those (P1); on Parameter Store both fields of a rotation arrived in one sync, on 2.11.0 (`matrix/r-tenant-store.sh` row B) and 0.20.3 (`parity/ssm-parity.sh`). |
| `template.type` with `engineVersion: v2` | The only way to produce a typed Secret (`kubernetes.io/tls`, a dockerconfigjson) from arbitrary backend fields. | **Measured**: a typed `kubernetes.io/tls` Secret from two fields (P1). |
| `remoteRef.version` on a key that shares a Secret | The guard for the key class when the consumer takes one Secret (§4). | **Measured**: a new version reaches nothing, the other keys keep refreshing (P2, P3); on Parameter Store the same, with the token beside the pinned key following its new version within one 5-second poll (row A), and 0.20.3 delivering the same pinned bytes (`parity/ssm-parity.sh`). Parameter Store keeps a parameter's last 100 versions and does not drop a labelled one, so label the version a pin names (read in the `PutParameter` reference, not exercised). |
| `refreshPolicy: Periodic`, interval chosen from the consumer | The interval is a promise about how stale a value may be. Choose it from what the consumer does with the value, not from a default. | **Measured** that it follows: a new version reached the Secret within one 30-second interval (P2). **Judgement**: an hour suits most consumers, and anything shorter is a load decision made on the backend's behalf. |
| `creationPolicy: Owner` | One manager per Secret, visible in the object itself. Pair it with the prune-disabled annotation (§3). | **Measured**: owner reference present (P1); garbage collection on deletion (`matrix/r12-key-class.sh`); on Parameter Store a deleted key-class `ExternalSecret` took its Secret at once, and re-applied from Git brought back the same pinned bytes, on 2.11.0 (row E) and 0.20.3 (`parity/ssm-parity.sh`). |
| `deletionPolicy: Retain` | A backend that answers "not found" — an outage, a policy change, a typo in a path — must not remove a Secret a pod has mounted. | **Measured**: the Secret survived its entry's deletion (P5). |
| The store that matches the identity | A namespaced `SecretStore` with TokenRequest auth per namespace identity; one `ClusterSecretStore` with `conditions.namespaces` on a delivered credential (§2). | **Judgement**, with the measured limits of each shape in §2. |

### Do not standardize

| Feature | Why not | Evidence |
| --- | --- | --- |
| `dataFrom.find` | It reports success for whatever it found. Remove a key from the matched set and it disappears from the Secret while the `ExternalSecret` stays green — the failure mode with no signal, which is the worst kind. Use it for exploration, never for delivery. | **Measured** on Vault with both operator versions (P6) and on Parameter Store (`matrix/r-aws-rows.sh`). |
| `deletionPolicy: Delete` on anything mounted | It converts a backend blip into a removed Secret, and a removed Secret under a `subPath` mount is not something a running pod recovers from. | **Measured**: the Secret was deleted within a minute of its entry (P4). |
| `ClusterExternalSecret` | One object that writes into every namespace can also empty every namespace; one `ExternalSecret` per namespace instead. Its reconciler is off in this repository's operator values. | **Judgement**. |
| A `ClusterSecretStore` without `conditions` | Every namespace, present and future, could read through it. | **Measured** that the list refuses what it does not name (row C). |
| Generators for anything with a lifetime | A generator mints a credential with an expiry the Kubernetes object knows nothing about. The Secret keeps looking correct after the credential behind it has expired, and the first signal is the application failing. Acceptable only where the lifetime is managed deliberately, with margin, and someone owns the renewal. | **Measured** (`matrix/r-sts-expiry.sh`): the consuming store failed while the ExternalSecret holding the minted credentials still reported success. |
| `PushSecret` | It syncs Kubernetes → external store, which is backwards: it makes the cluster the source of truth for material the cluster is supposed to consume. | **Judgement**. |
| `creationPolicy: Merge` into a foreign Secret | Refused by the operator, and rightly (§3). | **Measured** (`matrix/r12-key-class.sh`). |
| `refreshPolicy: CreatedOnce` as a default | Correct for the key class (§4) and wrong for everything else, where it pins a credential at its first value and no rotation ever reaches the cluster. | **Measured** that it never follows (P2); **judgement** that this is wrong for credentials. |

## 6. Shared credentials

When one credential is held by several applications, decide which of two things it is before
migrating it, because the answer changes the target shape:

- **Shared by design**: the protocol has two ends and both must hold the same value, or the
  credential identifies one logical application that happens to have several deployments. Keep it
  shared, deliver it by reference to each consumer, and record why.
- **Shared by packaging**: it is one credential because it arrived in one file, not because anything
  requires it. This is the common case, and it is worth undoing: per-application credentials give
  per-application blast radius, rotation without restarting every consumer, and an audit trail that names
  the caller.

The test that separates them is **"can the issuing side issue a second one?"** A message broker can
create a second user; an identity provider can create a second client; a certificate authority can
issue a second certificate. If it can, the sharing is packaging. A wildcard certificate is the
honest exception: it is one credential by design, and the several Secrets holding copies of it are a
consequence of each chart naming its own Secret, not of anything needing to be shared.

One caveat the store cannot fix: **if the application reads its credentials as literal values
templated into its manifests, changing the store changes nothing.** The value still ends up on the
workload's readable surface. Moving to an external store is only worth the work alongside changing
the consumer to read by reference — a Secret reference, an `envFrom`, or a mounted file.

## 7. What a delivered Secret does not give you

Two properties that are easy to assume and are not true:

- **A Secret following the backend is not the process following the backend.** The Secret changes
  within the refresh interval. A process holding the value in an environment variable never sees the
  new one, and a file mounted with `subPath` is not updated in place either — only a whole-volume
  mount is, and then only if the process re-reads it. Closing that gap needs a restart, which means
  either a deliberate rollout or a reloader (see `README.md` for the trade-off). **Measured** on this
  lab's application for environment delivery (`matrix/r15-reloader.sh`) and `subPath` delivery
  (`matrix/r11-subpath-under-reloader.sh`).
- **A green `SecretStore` is not a working store.** Its condition is the result of its own
  validation, which runs on its own schedule and tests only a login. With Vault sealed it went
  `InvalidProviderConfig` in one run (`matrix/r1-backend-unavailable.sh`) and stayed `Valid` through
  the whole outage in another (`matrix/r1b-file-delivery-outage.sh`); a revoked policy
  (`matrix/r2-permission-revoked.sh`), an unreachable Parameter Store endpoint
  (`matrix/r-aws-unreachable.sh`) and expired downstream credentials (`matrix/r-sts-expiry.sh`) left it
  `Valid` every time. The signal is the `ExternalSecret`'s condition, and the cause is in its events:
  its message says only which side failed — reading from the backend, or writing the Secret.
  **Measured**. On a delivered credential it is weaker still: the store's validation of a static
  key calls nothing, and it read `Valid` through a revoked key (§2, row D).

## 8. Five shapes, end to end

Most migrations are one of five shapes. Each is given here as the manifest it becomes, with the
decision that shape forces. The manifests use the Vault store; on a delivered credential the
decisions are the same with `ClusterSecretStore aws-parameterstore` as the store, paths under
`/devops/<cluster>/<namespace>/`, and a pair or a certificate as one JSON parameter (§1), and
`components/ssm-app-secrets/` shows 8.1, 8.2, 8.3 and 8.5 on it.

### 8.1 A single vendor key

One value, one consumer, read as an environment variable. The simplest case and the most common.

```yaml
spec:
  refreshPolicy: Periodic
  refreshInterval: 1h
  secretStoreRef: {name: vault, kind: SecretStore}
  target: {name: billing-api-vendor, creationPolicy: Owner, deletionPolicy: Retain}
  data:
  - secretKey: VENDOR_API_KEY
    remoteRef: {key: billing-api/vendor, property: VENDOR_API_KEY}
```

**The decision:** the interval is a promise about staleness, and the process will not see the new
value until it restarts. If the vendor can revoke at any moment, the application must survive a
reload, or a reloader (`README.md`) becomes part of the design rather than an option.

### 8.2 A credential pair

A username and a password are one account. They are replaced together, so they are one backend
entry and `dataFrom.extract` delivers both.

```yaml
  dataFrom:
  - extract: {key: billing-api/db}
```

**The decision:** whether every consumer gets its own account. If the issuing side can create a
second user, the answer is yes (§6) — and then rotating one consumer leaves every other consumer's
Secret and process untouched, which is the property a shared account can never have.

### 8.3 An encryption key

```yaml
spec:
  refreshPolicy: CreatedOnce
  secretStoreRef: {name: vault, kind: SecretStore}
  target: {name: billing-api-kek, creationPolicy: Owner, deletionPolicy: Retain}
  data:
  - secretKey: KEK
    remoteRef: {key: billing-api/kek, property: KEK}
```

Its own Secret, mounted as a file rather than an environment variable, and never composed with the
credentials. When the consumer only takes one Secret, compose it and pin the key's version instead:

```yaml
  data:
  - secretKey: KEK
    remoteRef: {key: billing-api/kek, property: KEK, version: "3"}   # moved by a reviewed commit only
  - secretKey: DB_PASSWORD
    remoteRef: {key: billing-api/db, property: password}              # refreshes as usual
```

**The decision:** nothing in the path may be able to generate a value. A generator, a
chart's `randAlphaNum` default or a `creationPolicy` fed by randomness turns "the backend is
unreachable" into "the data is gone", and the two are indistinguishable from inside the cluster.

### 8.4 A configuration blob becoming one Secret per application

The shape behind most of the work: a single file holding every service's credentials, pulled into
Helm values and rendered as literal environment variables. It becomes one `ExternalSecret` per
application, composing that application's keys from separate backend entries.

```yaml
  data:
  - secretKey: DB_PASSWORD
    remoteRef: {key: billing-api/db, property: password}
  - secretKey: SIGNING_KEY
    remoteRef: {key: billing-api/signing-key, property: SIGNING_KEY}
```

**The decision, and the real cost:** the chart must consume the Secret **by reference**
(`existingSecret`, `envFrom`, a mount), not by value. Until that changes, moving the storage
backend changes nothing — the credential still ends up templated onto the workload, readable by
anyone who can read a Deployment, and stored a second time in the Helm release history. That
per-application chart work, not the choice of backend, is what a migration actually costs.

### 8.5 A certificate

```yaml
  target:
    name: billing-api-tls
    creationPolicy: Owner
    deletionPolicy: Retain
    template:
      type: kubernetes.io/tls
      engineVersion: v2
      data:
        tls.crt: '{{ .crt }}'
        tls.key: '{{ .key }}'
  data:
  - secretKey: crt
    remoteRef: {key: billing-api/tls, property: tls.crt}
  - secretKey: key
    remoteRef: {key: billing-api/tls, property: tls.key}
```

**The decision:** this is *delivery*, not issuance. The operator will carry a renewed certificate
into the cluster; it will never notice that one is about to expire, and it will never ask for a new
one. Something else must renew — an ACME client, a certificate authority's own automation, a PKI
issuer — and if a certificate is copied into several Secret names, each copy needs its own
`ExternalSecret` or the renewal reaches some consumers and not others.

The two fields above are read one call each; `dataFrom.extract` reads the entry once. That matters
most for a certificate kept as two separate parameters, as another team may keep one: its renewal is
two writes, and a refresh landing between them pairs a new certificate with an old key for up to one
interval, which an ingress controller rejects. Ask whoever keeps it for one entry, or for a renewal
that writes both before anything reads (**Judgement**).
