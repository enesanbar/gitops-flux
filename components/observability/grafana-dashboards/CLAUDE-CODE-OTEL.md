# Claude Code observability — attribute convention & dashboards

How Claude Code telemetry is tagged and which dashboard shows what. The
dashboards are generated, not hand-edited — see [Regenerating](#regenerating).

## The pipeline (recap)

```
Claude Code (OTel SDK)
  → OTLP/gRPC https://otlp-grpc.kindcluster.dev:443
  → opentelemetry-collector (deltatocumulative; groupbyattrs/session)
      ├─ metrics → kube-prometheus-stack (Prometheus OTLP receiver)   → Grafana "Prometheus"
      ├─ logs/events → Loki (and SigNoz)                              → Grafana "Loki"
      └─ traces → Tempo / Jaeger / SigNoz                             → Grafana "Tempo"
```

Metrics are counters (`claude_code.*`). Events (`api_request`, `tool_result`,
`api_error`, …) are logs in Loki, reachable by their `event_name` structured
metadata. Latency panels read Tempo's span-metrics.

## The attribute convention

Claude Code already attaches rich built-in attributes to every metric:
`model`, `effort`, `query_source` (main/subagent/auxiliary), `agent.name`,
`skill.name`, `plugin.name`, `mcp_server.name`, `user.email`, `session.id`,
`start_type`, `type`, `decision`, `language`, … (full list:
<https://code.claude.com/docs/en/monitoring-usage>).

What the built-ins **cannot** tell you is *how a session was launched* —
interactive vs. a `claude -p` pod vs. a workflow step. A developer typing
`claude` and a pod running `claude -p` look identical. So we add a small set of
custom keys via `OTEL_RESOURCE_ATTRIBUTES`. With
`OTEL_METRICS_INCLUDE_RESOURCE_ATTRIBUTES=true` (the default) each key becomes a
queryable label on every metric series, and structured metadata on every event.

| Key | Values | Modes | Meaning |
|-----|--------|-------|---------|
| `run.mode` | `interactive` \| `automated` \| `workflow` | all | **Primary discriminator.** Which dashboard a series belongs to. |
| `run.user` | e.g. `enes` | all | Human owner. (`user.email` is the auth identity; `run.user` is the person responsible for an automated/workflow run, which may differ.) |
| `run.env` | `local` \| `ci` \| `prod` | all | Environment the run executed in. |
| `team.id` | e.g. `cloud-ai` | all | Team / cost-centre. Drives the "Cost by team" panel. |
| `run.role` | `coordinator` \| `planner` \| `developer` \| `reviewer` \| … | automated | The agent's role in a multi-agent system. |
| `run.task` | ticket / task id | automated | What the agent is working on. |
| `wf.id` | `wf_…` | workflow | Stable id shared by every session in one workflow run. |
| `wf.step` | `plan` \| `implement` \| `review` \| … | workflow | The stage within the workflow. |

> **Formatting rules** (strict): comma-separated `key=value`, **no spaces**, no
> quotes, no semicolons/backslashes. Percent-encode anything exotic. Wrapping in
> quotes does *not* escape spaces — `team.id="my team"` stores the literal
> quotes. Custom keys never override built-ins like `user.email`/`session.id`.

We also set `OTEL_METRICS_INCLUDE_ENTRYPOINT=true` so `app.entrypoint`
(`cli`/`sdk-cli`/`sdk-py`/`claude-vscode`) flows as a secondary signal.

### Setting it per mode

**Interactive** — `~/.claude/settings.json` (already applied on this machine):

```json
"env": {
  "OTEL_METRICS_INCLUDE_ENTRYPOINT": "true",
  "OTEL_RESOURCE_ATTRIBUTES": "run.mode=interactive,run.user=enes,run.env=local,team.id=cloud-ai"
}
```

**Automated** (`claude -p` in a pod) — set it in the pod/container env. The
owner, role, and task usually come from the launcher:

```yaml
env:
  - name: OTEL_RESOURCE_ATTRIBUTES
    value: "run.mode=automated,run.role=$(RUN_ROLE),run.user=$(RUN_USER),run.task=$(RUN_TASK),run.env=prod,team.id=cloud-ai"
```

**Workflow** (one script driving many sessions) — give every session the same
`wf.id` and mark its `wf.step`:

```bash
export OTEL_RESOURCE_ATTRIBUTES="run.mode=workflow,wf.id=${WF_ID},wf.step=plan,run.user=enes,run.env=ci,team.id=cloud-ai"
claude -p "…plan…"
export OTEL_RESOURCE_ATTRIBUTES="run.mode=workflow,wf.id=${WF_ID},wf.step=implement,run.user=enes,run.env=ci,team.id=cloud-ai"
claude -p "…implement…"
```

`env` vars do **not** merge — a pod/launcher that sets `OTEL_RESOURCE_ATTRIBUTES`
fully replaces any inherited value, so always include the full set.

### Cardinality note

Every custom key is a label on every series. Keep values **bounded**: `run.role`,
`wf.step`, `run.env`, `team.id` are low-cardinality — fine. `run.task` and
`wf.id` are higher; that's acceptable for a dev cluster but watch series growth
in production. `session.id` is already a label (default on). To shed labels
without losing the resource block, set
`OTEL_METRICS_INCLUDE_RESOURCE_ATTRIBUTES=false`. Never put unbounded values
(uuids per request, free text) in `OTEL_RESOURCE_ATTRIBUTES`.

## The dashboards (Grafana folder `claude-code`)

| Dashboard | uid | Scope | Populated by |
|-----------|-----|-------|--------------|
| **Claude Code · Overview** | `claude-code-usage` | All modes — fleet cost, tokens (incl. cache), sessions, productivity, reliability events, latency. Filters: mode, user, model, effort, query source, team, env, session. | Live now. |
| **Claude Code · Automated Agents** | `claude-code-automated` | `run.mode=automated` — cost/tokens by role, task, user; per-session table; error/refusal/retry rates. | Once pods set `run.mode=automated`. |
| **Claude Code · Workflows** | `claude-code-workflows` | series with a `wf.id` — per-workflow & per-step cost/tokens, reliability. | Once workflow sessions set `wf.id`. |

All three dashboards share the same filter set (mode/user/model/effort/team/env/session,
plus mode-specific role/task/wf/step). Panels that read empty show a hint (e.g.
"no team.id yet — set team.id=… in OTEL_RESOURCE_ATTRIBUTES"); they light up
automatically once the attribute flows.

## How totals are aggregated (important)

`claude_code.*` are **cumulative counters scoped per session** — each session.id is
its own monotonic series that stops reporting (goes stale) when the session ends. That
breaks the two obvious aggregations:

- A plain instant `sum(metric)` only sees series with a sample in the last ~5 min, so it
  collapses to the cost of *currently-live* sessions (near-zero when nothing is running).
  This is why an early version showed a $1.39 headline against $20 of real spend.
- `rate(metric[$__rate_interval]) * $__rate_interval` summed across a chart **over**-counts,
  because Grafana's rate windows overlap (`$__rate_interval` ≈ 4× the step).

So the generator uses:

- **Totals** (headline stats, pies, bargauges, tables, ratios, distinct counts) →
  `sum(max_over_time(metric[$__range]))`: each series' final cumulative value over the
  whole range, stale or not. This is the true spend in the window, and headline = pie =
  table all agree.
- **Trends** ("… over time" charts) → `sum by (…) (increase(metric[$__interval]))`:
  non-overlapping per-interval deltas. These show *shape*; their legend deliberately drops
  the "Total" calc (it would read ~20–30% under the headline — `increase()` can't capture a
  session's first cumulative sample under delta-origin temporality). The authoritative
  totals live in the headline / pies / tables, not the trend legend.

When adding a panel: counters get `max_over_time(…[$__range])` for a total or
`increase(…[$__interval])` for a trend — never a bare instant `sum()`.

## Before fleet-wide rollout (known follow-ups)

These are fine on the dev cluster but worth doing before this fans out widely:

- **Recording rules for the rolling-window gauges.** "Tokens used in last 5h/7d"
  run `sum(increase(token_total[5h|7d]))` over the highest-cardinality counter.
  At dashboard scale, back them with Prometheus recording rules
  (`claude_code:token_usage:increase7d`, …) and point the gauges at the recorded
  series. Dashboard refresh is already set to `5m` to keep this cheap meanwhile.
- **Cost split by cache is not directly available.** `claude_code.cost.usage` has
  no token-`type` label, so we can show tokens cached-vs-fresh and a blended
  "cost per 1M tokens", but not the *dollars* attributable to cache vs fresh. A
  true cache-$-savings panel needs a per-model price table (PromQL recording
  rules multiplying token counts by hard-coded prices) — deliberately not faked.
- **Keep `run.task` / `wf.id` coarse.** They become labels on every series;
  unbounded values (one per request) will grow the series count. Per-task /
  per-workflow ids are fine; per-invocation uuids are not.

## Regenerating

The JSON is built by `gen_dashboards.py` (next to the dashboards). `kustomize`
only picks up the `.json` files, so the generator ships alongside them without
being rendered into the ConfigMap. It owns the shared filter-injection idiom
(dotted OTel labels must be quoted in PromQL: `{"user.email"=~"$user"}`), panel
layout, and unique ids. Edit the generator, re-run it, and it overwrites the
three JSON files in place; `kustomize` re-renders them into the
`grafana-dashboard-claude-code` ConfigMap, which Grafana's sidecar reloads.

```bash
python3 gen_dashboards.py
kubectl kustomize components/observability/grafana-dashboards   # sanity render
```
