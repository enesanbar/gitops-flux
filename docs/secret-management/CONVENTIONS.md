# Conventions for delivering secrets with the External Secrets Operator

What follows is what the experiments in this repository settled, stated as rules with the reason
attached. Where a rule exists because something was measured, the measurement is named. Where it is
a judgement call, it says so.

The scope is **delivery**: getting a value that lives in an external store into a Kubernetes Secret,
and from there into a process. Issuance (minting a certificate, creating a database user) is a
different problem and is called out where the two are easy to confuse.

## 1. Where secrets live in the backend

### The rule

Put in the path only what is **stable** and what a **policy has to cut on**. Everything else —
owning team, ticket, cost centre, who asked for it — belongs in metadata, because a path is an
identifier that consumers hard-code and metadata is not.

Two things qualify: the **environment** (a policy boundary, an account boundary, and the thing you
must never let leak across) and the **application** (the unit that owns, rotates and loses a
secret). Team does not: teams reorganize, and every rename breaks every consumer.

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

### AWS Systems Manager Parameter Store

**Recommended:** `/<environment>/<application>/<name>`, one parameter per value.

```
/prod/billing-api/db-password
/prod/billing-api/signing-key
/stage/billing-api/db-password
```

Environment leads because IAM policies glob on a path prefix (`arn:aws:ssm:…:parameter/prod/*`), and
because environments usually already sit in separate accounts — the path then reinforces a boundary
that already exists instead of inventing a new one. Parameter Store has no equivalent of a Vault
entry with several fields, so a credential pair is two parameters composed back together by the
`ExternalSecret`; `dataFrom.find` can enumerate a prefix instead, and §5 explains why you should not.

### How the two shapes score

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

## 2. Namespaced stores, not cluster-scoped ones

**Rule: a `SecretStore` in the application's namespace, never a `ClusterSecretStore`, unless the
material is platform-owned and identical everywhere.** In this repository the cluster-scoped
controllers are switched off in the operator's own values, so the rule is enforced rather than
documented.

The reason is identity. A namespaced store authenticates as **that namespace's** ServiceAccount, so
the backend policy can be written per application and the audit trail names the application. A
cluster-scoped store authenticates once, for everybody, so the backend sees one identity reading
everything and the only remaining boundary is Kubernetes RBAC on who may create an `ExternalSecret`
— a boundary that is easy to widen by accident and invisible from the backend side.

The identity is a short-lived token minted through the TokenRequest API with an audience, never a
ServiceAccount token Secret mounted into a pod. Grant the operator `create` on
`serviceaccounts/token` for **that one ServiceAccount by name** (`resourceNames`), which is what
`components/trellis-secrets/rbac.yaml` does.

Cluster-scoped is the right answer for exactly one shape: material the platform owns, that is byte
-identical in every namespace, and whose reader identity genuinely is "the cluster" — a private
registry pull credential, for instance. Even then, prefer one `ExternalSecret` per namespace over a
`ClusterExternalSecret`, because a single object that writes into every namespace is also a single
object that can empty every namespace.

## 3. One authoritative manager per Secret

**Rule: every Kubernetes Secret has exactly one thing that creates and updates it, and you can name
that thing from the Secret alone.**

| Secret class | Its manager | Never |
| --- | --- | --- |
| Application credentials from an external store | An `ExternalSecret` with `creationPolicy: Owner` | A chart that also templates the same Secret |
| Certificates issued in-cluster | cert-manager's `Certificate` | An `ExternalSecret` pointing at the same name |
| Operator-internal credentials (database operators, brokers) | That operator | Anything else; the operator will reconcile you away |
| Chart-generated internals (cookies, admin passwords) | The chart | Moving them to the store for its own sake |

Two consequences that were measured rather than assumed:

- **`creationPolicy: Owner` puts an owner reference on the Secret**, so deleting or renaming the
  `ExternalSecret` garbage-collects the running application's Secret. In a GitOps repository that
  makes a *pruning* event — a moved file, a renamed component — into an outage. Application
  `ExternalSecret`s therefore carry `kustomize.toolkit.fluxcd.io/prune: disabled`. `deletionPolicy:
  Retain` does not help here: it covers a vanished **backend** entry, not a vanished ExternalSecret.
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
  a process that re-reads it will decrypt nothing.
- Use `deletionPolicy: Retain`, so a backend blip cannot remove the key from under a mounted volume.
- Never put it behind a generator, a chart `randAlphaNum` default, or anything else that can produce
  a *new* value when the old one is missing. Silent regeneration of a key is indistinguishable from
  total data loss, and it happens at the worst possible moment: when the backend is unreachable.

## 5. Operator features: what to standardize, and what to refuse

### Standardize

| Feature | Why |
| --- | --- |
| Explicit `data[]` mapping | The `ExternalSecret` states every key it produces, so a reviewer can see the Secret's shape without reading the backend, and a key that disappears upstream becomes an error rather than an absence. |
| `dataFrom.extract` for one entry | The right tool for a credential *pair* — a username and password replaced together are one entry, and naming both fields separately invites them to drift apart. |
| `template.type` with `engineVersion: v2` | The only way to produce a typed Secret (`kubernetes.io/tls`, a dockerconfigjson) from arbitrary backend fields. Guard every field access with `with`: a template that reads an absent field does not fail, it renders the raw object into your Secret. |
| `refreshPolicy: Periodic`, interval chosen from the consumer | The interval is a promise about how stale a value may be. Choose it from what the consumer does with the value, not from a default: an hour is right for most things, and anything shorter is a load decision you are making on the backend's behalf. |
| `creationPolicy: Owner` | One manager per Secret, visible in the object itself. Pair it with the prune-disabled annotation (§3). |
| `deletionPolicy: Retain` | A backend that answers "not found" — because of an outage, a policy change, a typo in a path — must not remove a Secret a pod has mounted. |
| A namespaced `SecretStore` with TokenRequest auth | §2. |

### Do not standardize

| Feature | Why not |
| --- | --- |
| `dataFrom.find` | It reports success for whatever it found. Remove a key from the matched set and it disappears from the Secret while the `ExternalSecret` stays green — the failure mode with no signal, which is the worst kind. Use it for exploration, never for delivery. |
| `deletionPolicy: Delete` on anything mounted | It converts a backend blip into a removed Secret, and a removed Secret under a `subPath` mount is not something a running pod recovers from. |
| `ClusterSecretStore` and `ClusterExternalSecret` | §2. Both are off in this repository's operator values. |
| Generators for anything with a lifetime | A generator mints a credential with an expiry the Kubernetes object knows nothing about. The Secret keeps looking correct long after the credential behind it has expired, and the first signal is the application failing. Acceptable only where the lifetime is managed deliberately, with margin, and someone owns the renewal. |
| `PushSecret` | It syncs Kubernetes → external store, which is backwards: it makes the cluster the source of truth for material the cluster is supposed to be a consumer of. |
| `creationPolicy: Merge` into a foreign Secret | Refused by the operator, and rightly (§3). |
| `refreshPolicy: CreatedOnce` as a default | Correct for the key class (§4) and wrong for everything else, where it silently pins a credential at its first value and no rotation ever reaches the cluster. |

## 6. Shared credentials

When one credential is held by several applications, decide which of two things it is before
migrating it, because the answer changes the target shape:

- **Shared by design**: the protocol has two ends and both must hold the same value, or the
  credential identifies one logical application that happens to have several deployments. Keep it
  shared, deliver it by reference to each consumer, and record why.
- **Shared by packaging**: it is one credential because it arrived in one file, not because anything
  requires it. This is the common case, and it is worth undoing: per-application credentials give
  per-application blast radius, rotation without a fleet-wide restart, and an audit trail that names
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
  either a deliberate rollout or a reloader (see `README.md` for the trade-off).
- **A green `SecretStore` is not a working store.** The store's condition reflects its last
  validation, not the current state of the backend. The signal that matters is the `ExternalSecret`'s
  own condition and its message.

## 8. Five shapes, end to end

Most migrations are one of five shapes. Each is given here as the manifest it becomes, with the
decision that shape forces.

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
reload, or the reloader in §5 becomes part of the design rather than an option.

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
credentials. **The decision:** nothing in the path may be able to generate a value. A generator, a
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
