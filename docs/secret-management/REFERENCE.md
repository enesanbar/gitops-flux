# Which parts of this repository are a reference, and which are lab material

This repository is a personal lab, so most of what it contains under `components/` exists to be
measured rather than copied. The split below is the answer to "I want this pattern in my cluster —
which file do I start from?"

A **reference** component is one whose shape is the recommendation: copy it, rename it, change the
paths. **Lab material** is kept so the measurements taken with it can be reproduced; it is shaped to
provoke a failure, to stand two mechanisms side by side, or to hold a credential a real cluster
would not have. Reading it is useful. Copying it is not.

## Reference

| Path | What it is | What to change when you copy it |
| --- | --- | --- |
| `components/external-secrets/` | The External Secrets Operator install, least privilege first. The `ClusterSecretStore` reconciler is on, because a cluster that is handed one credential reads it through one cluster-scoped store (CONVENTIONS.md §2); the `ClusterExternalSecret`, `PushSecret` and `ClusterPushSecret` reconcilers are off; cluster generators are off by withholding their RBAC; and `rbac.serviceAccountTokenCreate: false` removes the operator's cluster-wide right to request ServiceAccount tokens. That is hygiene, not a bound: the operator still creates and reads Secrets cluster-wide, which is enough to obtain a token for any ServiceAccount (CONVENTIONS.md §2). | The chart version — and read CONVENTIONS.md §2 first if yours is older than 2.5.0, where that switch does not exist. |
| `components/trellis-secrets/` | The application pattern end to end: a namespaced `SecretStore` with a per-namespace identity, a composed `ExternalSecret` that assembles one application Secret from several backend paths — with the encryption key pinned to one backend version, because the chart takes a single Secret — and a second `ExternalSecret` producing a typed `kubernetes.io/tls` Secret. Its Flux `Kustomization` carries the `healthCheckExprs` of `ssm-app-secrets`, plus one waiting on the store's own Ready. | Namespace, ServiceAccount name, Vault role, mount and paths, the pinned version, and the key names the chart expects. |
| `components/aws-parameterstore/` | The store of a cluster that is handed one credential: a `ClusterSecretStore` on AWS Parameter Store that reads the delivered Secret (`external-secrets/aws-credentials`, never in this repository) and lists the namespaces that may use it. The list scopes namespaces, not paths (CONVENTIONS.md §2). It is never pruned, and its Flux `Kustomization` waits on the store's own Ready condition. | The region, the Secret's name, namespace and keys as your platform delivers them, and the namespace list. |
| `components/ssm-app-secrets/` | The application pattern on that store. Every path of its own is `/devops/<cluster>/<namespace>/…` with free nesting below the namespace; an encryption key pinned to one parameter version, sharing a Secret with a token that follows the latest only to show the pin (CONVENTIONS.md §4 gives a key a Secret of its own by default); a credential kept as one JSON parameter and read with one `dataFrom.extract`; a certificate read as it is kept in another team's realm (`/dev-generic/` stands in for it here) and rendered as `kubernetes.io/tls`. Its Flux `Kustomization` carries `healthCheckExprs`, because kstatus alone reads a status-less or stale `ExternalSecret` as ready. | Namespace, paths, the key names the consumer expects, the pinned version, and the other team's path for the certificate. |
| `components/reloader/` | Optional, and an explicit trade rather than a default. Restarts a workload when a Secret it consumes changes, which is the only way an environment variable or a `subPath`-mounted file ever reaches a running process. | The namespace selector, which names one lab namespace here. Read the trade-off in `README.md` first: cluster-wide read on Secrets, fan-out restarts, a content digest left on the workload — and never adopt it for a Secret that carries an unpinned encryption key. |

## Lab and experiment material — read, do not copy

| Path | Why it exists | Why not to copy it |
| --- | --- | --- |
| `components/secret-example-eso/`, `-sealed/`, `-vso/` | One secret delivered three ways side by side, so the three mechanisms can be compared on one cluster. | Three mechanisms delivering the same value is exactly what a real cluster must not do: one authoritative manager per Secret. |
| `components/secret-stores/` | The shared stores and namespaces those three examples authenticate through. | Its identity is shared across the example namespaces to keep the comparison cheap; a real store is per namespace. |
| `components/secret-lab-aws/` | An AWS Parameter Store backend in two shapes — a long-lived static key, and short-lived credentials minted by Vault's AWS engine — plus the composition, `find`-and-`rewrite` and typed-TLS variants used to measure them. | It deliberately holds the shapes the conventions **reject** next to the ones they accept, for comparison. `README.md` in that directory says which is which. |
| `components/secret-lab-pki/` | Certificate *issuance* from a Vault PKI, judged apart from delivery: a 72-hour leaf re-issued daily by the operator's generator, and one renewed every 48 hours by cert-manager. | It exists to keep both issuance paths observable. Issuance is not the operator's job (CONVENTIONS.md §8.5), and a generator-issued certificate expires on a clock the Kubernetes object knows nothing about. |
| `scripts/secrets/experiments/` | Everything hands-on: tenant auth mounts, the key-at-process-start experiment, the PKI issuer, the lab account's IAM for Parameter Store, the rotation and failure matrix, and two operator-version parity gates. | Nothing here is applied by Flux and nothing here is a recommended pattern. `README.md` in that directory is the index. |

## The rule behind the split

Every lab object under `components/` lives in a namespace whose name begins `secret-lab-`, or in one
of the `secret-example-` components. That test runs one way only: **if the namespace says "lab", the
manifest is evidence, not advice** — but a manifest outside those namespaces is not thereby a
reference. The five rows above are the whole reference set.

The conventions the reference components implement — path layouts, store scoping, ownership,
and which operator features to standardize — are in [CONVENTIONS.md](CONVENTIONS.md). The
day-to-day commands are in [README.md](README.md).
