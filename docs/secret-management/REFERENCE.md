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
| `components/external-secrets/` | The External Secrets Operator install. The cluster-scoped controllers (`ClusterSecretStore`, `ClusterExternalSecret`, `PushSecret`, cluster generators) are **off**, so a namespace cannot be served a store it does not own and a single object cannot write into every namespace. | The chart version, and the controller switches only if you have decided you need one of them. |
| `components/trellis-secrets/` | The application pattern end to end: a namespaced `SecretStore` with a per-namespace identity, a composed `ExternalSecret` that assembles one application Secret from several backend paths, and a second `ExternalSecret` producing a typed `kubernetes.io/tls` Secret. | Namespace, ServiceAccount name, Vault role, mount and paths, the refresh interval, and the key names the chart expects. |
| `components/reloader/` | Optional. Restarts a workload when a Secret it consumes changes, which is the only way an environment variable or a `subPath`-mounted file ever reaches a running process. Namespace-scoped by selector. | The namespace selector. Read the trade-off in `README.md` before adopting it: it needs cluster-wide read on Secrets, and it leaves a content digest on the workload. |

## Lab and experiment material — read, do not copy

| Path | Why it exists | Why not to copy it |
| --- | --- | --- |
| `components/secret-example-eso/`, `-sealed/`, `-vso/` | One secret delivered three ways side by side, so the three mechanisms can be compared on one cluster. | Three mechanisms delivering the same value is exactly what a real cluster must not do: one authoritative manager per Secret. |
| `components/secret-stores/` | The shared stores and namespaces those three examples authenticate through. | Its identity is shared across the example namespaces to keep the comparison cheap; a real store is per namespace. |
| `components/secret-lab-aws/` | An AWS Parameter Store backend in two shapes — a long-lived static key, and short-lived credentials minted by Vault's AWS engine — plus the composition, `find`-and-`rewrite` and typed-TLS variants used to measure them. | It deliberately holds the shapes the conventions **reject** next to the ones they accept, for comparison. `README.md` in that directory says which is which. |
| `components/secret-lab-pki/` | Certificate *issuance* from a Vault PKI, judged apart from delivery: a short-lived leaf re-issued on a loop. | The issuing loop exists to make renewal observable within an afternoon. A real leaf lifetime is not one hour. |
| `scripts/secrets/experiments/` | Everything hands-on: tenant auth mounts, the key-at-process-start experiment, the PKI issuer, the rotation and failure matrix, and the operator-version parity gate. | Nothing here is applied by Flux and nothing here is a recommended pattern. `README.md` in that directory is the index. |

## The rule behind the split

Every object under `components/` that is lab material lives in a namespace whose name begins
`secret-lab-`, or in one of the `secret-example-` components. Anything that is a reference lives in
the namespace of the application it belongs to. That is the quickest test when this table falls out
of date: **if the namespace says "lab", the manifest is evidence, not advice.**

The conventions the reference components implement — path layouts, store scoping, ownership,
and which operator features to standardize — are in [CONVENTIONS.md](CONVENTIONS.md). The
day-to-day commands are in [README.md](README.md).
