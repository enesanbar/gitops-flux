#!/usr/bin/env python3
"""Generate the three Claude Code Grafana dashboards.

Why a generator instead of hand-written JSON: three dashboards share the same
metric catalog, the same filter-injection idiom (dotted OTel labels must be
quoted in PromQL: {"user.email"=~"$user"}), and the same panel recipes.
Hand-maintaining ~1500 lines of JSON across three files drifts immediately.
This script is the source of truth; the JSON is the build artifact.

Metric catalog (verified against live Prometheus), with the labels each carries:
  cost   claude_code.cost.usage_USD_total        user.email model effort query_source
                                                  run.mode run.env team.id session.id
                                                  agent.name skill.name plugin.name mcp_*
  token  claude_code.token.usage_tokens_total    cost labels + type(input/output/cacheRead/cacheCreation)
  sess   claude_code.session.count_total         user.email run.* team.id session.id start_type   (no model/effort/query_source)
  act    claude_code.active_time.total_seconds_total  base + type(user/cli)
  loc    claude_code.lines_of_code.count_total   base + type(added/removed) + model(v2.1.172+)
  commit claude_code.commit.count_total          base
  pr     claude_code.pull_request.count_total    base
  edit   claude_code.code_edit_tool.decision_total  base + decision source language tool_name

Events live in Loki (stream {service_name=~"claude-code.*"}), with event.name as
structured metadata reachable as `| event_name="..."`. Dots become underscores
in Loki (session.id -> session_id, run.mode -> run_mode, user.email -> user_email).
"""
import json

COST   = "claude_code.cost.usage_USD_total"
TOK    = "claude_code.token.usage_tokens_total"
SESS   = "claude_code.session.count_total"
ACT    = "claude_code.active_time.total_seconds_total"
LOC    = "claude_code.lines_of_code.count_total"
COMMIT = "claude_code.commit.count_total"
PR     = "claude_code.pull_request.count_total"
EDIT   = "claude_code.code_edit_tool.decision_total"

# Token-type matchers (kept as module constants: f-strings can't hold backslashes).
CR    = 'type="cacheRead"'
CRCI  = 'type=~"cacheRead|cacheCreation|input"'
FRESH = 'type=~"input|cacheCreation"'  # input-side only; mirrors the cache-ratio denominator (excludes output)

PROM = {"type": "prometheus", "uid": "${datasource}"}
LOKI = {"type": "loki", "uid": "${loki}"}

# Loki event stream selector. Filtered by indexed session_id; mode/user are
# structured metadata applied via line-attribute filters in each query.
LSTREAM = '{service_name=~"claude-code.*", session_id=~"$session"}'


def sel(name, frags, *extra):
    parts = [f'__name__="{name}"'] + list(frags) + list(extra)
    return "{" + ", ".join(parts) + "}"


class Layout:
    """Auto-flow gridPos so panels never overlap and rows wrap at 24 cols."""
    def __init__(self):
        self.x = 0; self.y = 0; self.rowh = 0

    def place(self, w, h):
        if self.x + w > 24:
            self.x = 0; self.y += self.rowh; self.rowh = 0
        pos = {"h": h, "w": w, "x": self.x, "y": self.y}
        self.x += w; self.rowh = max(self.rowh, h)
        return pos

    def row_pos(self):
        if self.x > 0:
            self.y += self.rowh
        self.x = 0; self.rowh = 0
        pos = {"h": 1, "w": 24, "x": 0, "y": self.y}
        self.y += 1
        return pos


class Builder:
    def __init__(self):
        self.panels = []
        self.lo = Layout()
        self._id = 0

    def nid(self):
        self._id += 1
        return self._id

    def row(self, title):
        self.panels.append({
            "type": "row", "id": self.nid(), "title": title,
            "gridPos": self.lo.row_pos(), "collapsed": False, "panels": []
        })

    def _targets(self, targets):
        out = []
        for i, t in enumerate(targets):
            ds = LOKI if t.get("loki") else PROM
            tgt = {"refId": t.get("refId", chr(65 + i)), "datasource": ds,
                   "expr": t["expr"]}
            if "legend" in t:
                tgt["legendFormat"] = t["legend"]
            if t.get("instant"):
                tgt["instant"] = True; tgt["format"] = t.get("format", "table")
                tgt["range"] = False
            if t.get("range_table"):
                tgt["format"] = "table"
            return_format = t.get("format")
            if return_format and not t.get("instant"):
                tgt["format"] = return_format
            out.append(tgt)
        return out

    def stat(self, title, targets, w=4, h=4, unit="short", decimals=0,
             color="value", graph="area", text="value", thresholds=None,
             desc=None, mappings=None, novalue=None):
        fc = {"unit": unit, "decimals": decimals}
        if thresholds:
            fc["thresholds"] = thresholds
            fc["color"] = {"mode": "thresholds"}
        if mappings:
            fc["mappings"] = mappings
        if novalue:
            fc["noValue"] = novalue
        p = {"id": self.nid(), "type": "stat", "title": title,
             "datasource": PROM, "gridPos": self.lo.place(w, h),
             "targets": self._targets(targets),
             "fieldConfig": {"defaults": fc, "overrides": []},
             "options": {"reduceOptions": {"calcs": ["lastNotNull"]},
                         "colorMode": ("background" if color == "background" else
                                       ("background_solid" if color == "bgsolid" else "value")),
                         "graphMode": graph, "textMode": text, "justifyMode": "auto"}}
        if desc:
            p["description"] = desc
        return self._add(p)

    def timeseries(self, title, targets, w=12, h=8, unit="short", draw="line",
                   fill=30, stack=False, decimals=None, legend_calcs=None,
                   place="bottom", desc=None, overrides=None):
        cf = {"drawStyle": draw, "fillOpacity": fill, "lineWidth": 1}
        if stack:
            cf["stacking"] = {"mode": "normal"}
        defaults = {"unit": unit, "custom": cf}
        if decimals is not None:
            defaults["decimals"] = decimals
        p = {"id": self.nid(), "type": "timeseries", "title": title,
             "datasource": PROM, "gridPos": self.lo.place(w, h),
             "targets": self._targets(targets),
             "fieldConfig": {"defaults": defaults, "overrides": overrides or []},
             "options": {"legend": {"calcs": legend_calcs or ["mean", "max", "lastNotNull"],
                                    "displayMode": "table", "placement": place},
                         "tooltip": {"mode": "multi", "sort": "desc"}}}
        if desc:
            p["description"] = desc
        return self._add(p)

    def pie(self, title, targets, w=8, h=8, unit="short", desc=None):
        p = {"id": self.nid(), "type": "piechart", "title": title,
             "datasource": PROM, "gridPos": self.lo.place(w, h),
             "targets": self._targets(targets),
             "fieldConfig": {"defaults": {"unit": unit}, "overrides": []},
             "options": {"pieType": "donut", "displayLabels": ["percent"],
                         "legend": {"displayMode": "table", "placement": "right",
                                    "values": ["value", "percent"]},
                         "reduceOptions": {"calcs": ["lastNotNull"]}}}
        if desc:
            p["description"] = desc
        return self._add(p)

    def bargauge(self, title, targets, w=12, h=8, unit="short", mode="gradient",
                 desc=None, novalue=None):
        fc = {"unit": unit}
        if novalue:
            fc["noValue"] = novalue
        p = {"id": self.nid(), "type": "bargauge", "title": title,
             "datasource": PROM, "gridPos": self.lo.place(w, h),
             "targets": self._targets(targets),
             "fieldConfig": {"defaults": fc, "overrides": []},
             "options": {"orientation": "horizontal", "displayMode": mode,
                         "reduceOptions": {"calcs": ["lastNotNull"]},
                         "showUnfilled": True}}
        if desc:
            p["description"] = desc
        return self._add(p)

    def gauge(self, title, targets, w=6, h=8, unit="short", maxvar=None, desc=None):
        thr = {"mode": "percentage", "steps": [
            {"color": "green", "value": None}, {"color": "yellow", "value": 60},
            {"color": "orange", "value": 80}, {"color": "red", "value": 95}]}
        defaults = {"unit": unit, "min": 0, "decimals": 0, "thresholds": thr}
        overrides = []
        if maxvar:
            overrides = [{"matcher": {"id": "byName", "options": title},
                          "properties": [{"id": "max", "value": maxvar}]}]
        p = {"id": self.nid(), "type": "gauge", "title": title,
             "datasource": PROM, "gridPos": self.lo.place(w, h),
             "targets": self._targets(targets),
             "fieldConfig": {"defaults": defaults, "overrides": overrides},
             "options": {"showThresholdLabels": False, "showThresholdMarkers": True,
                         "reduceOptions": {"calcs": ["lastNotNull"]}}}
        if desc:
            p["description"] = desc
        return self._add(p)

    def table(self, title, targets, w=24, h=10, rename=None, units=None, desc=None):
        org = {"id": "organize", "options": {
            "excludeByName": {"Time": True},
            "renameByName": rename or {}}}
        transformations = [{"id": "merge", "options": {}}, org]
        overrides = []
        for fld, unit in (units or {}).items():
            overrides.append({"matcher": {"id": "byName", "options": fld},
                              "properties": [{"id": "unit", "value": unit},
                                             {"id": "custom.cellOptions",
                                              "value": {"type": "color-background", "mode": "gradient"}}]
                              if unit == "currencyUSD" else
                              [{"id": "unit", "value": unit}]})
        p = {"id": self.nid(), "type": "table", "title": title,
             "datasource": PROM, "gridPos": self.lo.place(w, h),
             "targets": self._targets(targets),
             "transformations": transformations,
             "fieldConfig": {"defaults": {"custom": {"filterable": True}}, "overrides": overrides},
             "options": {"showHeader": True, "cellHeight": "sm",
                         "sortBy": [{"displayName": (list((units or {}).keys()) or ["Value #A"])[0],
                                     "desc": True}]}}
        if desc:
            p["description"] = desc
        return self._add(p)

    def text(self, title, content, w=24, h=4):
        p = {"id": self.nid(), "type": "text", "title": title,
             "gridPos": self.lo.place(w, h),
             "options": {"mode": "markdown", "content": content}}
        return self._add(p)

    def _add(self, p):
        self.panels.append(p)
        return p


# ---------------------------------------------------------------------------
# Template variable factories
# ---------------------------------------------------------------------------
def var_ds(name="datasource", q="prometheus", label=None):
    return {"name": name, "type": "datasource", "query": q,
            "current": {"text": q.capitalize(), "value": q, "selected": False},
            "hide": 0, "refresh": 1, "regex": "", "label": label}


def var_query(name, label, metric, target_label, allvalue=None, hide=0, regex="", desc=None):
    q = f'label_values({{__name__="{metric}"}}, {target_label})'
    v = {"name": name, "label": label, "type": "query", "datasource": PROM,
         "definition": q, "query": {"query": q, "refId": "var"},
         "current": {"text": "All", "value": "$__all", "selected": True},
         "includeAll": True, "multi": True, "refresh": 2, "sort": 1,
         "hide": hide, "regex": regex}
    if allvalue:
        v["allValue"] = allvalue
    if desc:
        v["description"] = desc
    return v


def var_const(name, label, value, desc=None):
    v = {"name": name, "label": label, "type": "constant",
         "current": {"text": value, "value": value, "selected": False},
         "query": value, "hide": 0, "skipUrlSync": False}
    if desc:
        v["description"] = desc
    return v


def dashboard(uid, title, panels, variables, description, tags):
    return {
        "annotations": {"list": [{"builtIn": 1,
            "datasource": {"type": "grafana", "uid": "-- Grafana --"},
            "enable": True, "hide": True, "iconColor": "rgba(0, 211, 255, 1)",
            "name": "Annotations & Alerts", "type": "dashboard"}]},
        "description": description, "editable": True, "fiscalYearStartMonth": 0,
        "graphTooltip": 1, "id": None, "links": [
            {"title": "Overview", "type": "link", "url": "/d/claude-code-usage", "icon": "dashboard"},
            {"title": "Automated", "type": "link", "url": "/d/claude-code-automated", "icon": "dashboard"},
            {"title": "Workflows", "type": "link", "url": "/d/claude-code-workflows", "icon": "dashboard"},
        ],
        "panels": panels, "refresh": "5m", "schemaVersion": 39,
        "tags": tags, "templating": {"list": variables},
        "time": {"from": "now-24h", "to": "now"},
        "timepicker": {"refresh_intervals": ["10s", "30s", "1m", "5m", "15m", "30m", "1h", "6h", "12h"]},
        "timezone": "browser", "title": title, "uid": uid, "version": 1, "weekStart": ""
    }


# ===========================================================================
# OVERVIEW dashboard — all modes, the money + tokens + health view
# ===========================================================================
def build_overview():
    b = Builder()
    FULL = ['"user.email"=~"$user"', 'model=~"$model"', 'effort=~"$effort"',
            'query_source=~"$query_source"', '"run.mode"=~"$mode"',
            '"run.env"=~"$env"', '"team.id"=~"$team"', '"session.id"=~"$session"']
    # token/cost minus the session matcher, for "by session" groupings
    FULL_NS = [f for f in FULL if "session.id" not in f]
    BASE = ['"user.email"=~"$user"', '"run.mode"=~"$mode"', '"run.env"=~"$env"',
            '"team.id"=~"$team"', '"session.id"=~"$session"']

    GREEN = {"mode": "absolute", "steps": [{"color": "green", "value": None},
             {"color": "yellow", "value": 50}, {"color": "red", "value": 200}]}

    b.row("Headline")
    b.stat("Total Cost", [{"expr": f"sum({sel(COST, FULL)})", "legend": "USD"}],
           unit="currencyUSD", decimals=2, color="bgsolid", thresholds=GREEN)
    b.stat("Total Tokens", [{"expr": f"sum({sel(TOK, FULL)})"}], unit="short", decimals=1)
    b.stat("Sessions", [{"expr": f"sum({sel(SESS, BASE)})"}])
    b.stat("Active Time", [{"expr": f"sum({sel(ACT, BASE)})"}], unit="s")
    b.stat("Lines of Code", [{"expr": f"sum by (type) ({sel(LOC, BASE)})", "legend": "{{type}}"}],
           text="value_and_name")
    b.stat("Commits / PRs",
           [{"expr": f"sum({sel(COMMIT, BASE)}) or vector(0)", "legend": "Commits"},
            {"expr": f"sum({sel(PR, BASE)}) or vector(0)", "legend": "PRs"}],
           graph="none", text="value_and_name")

    b.row("Cost breakdown")
    b.pie("Cost by model", [{"expr": f"sum by (model) ({sel(COST, FULL)})", "legend": "{{model}}"}],
          unit="currencyUSD")
    b.pie("Cost by mode", [{"expr": f'sum by ("run.mode") ({sel(COST, FULL)})', "legend": "{{run.mode}}"}],
          unit="currencyUSD", desc="interactive / automated / workflow — set via run.mode in OTEL_RESOURCE_ATTRIBUTES.")
    b.pie("Cost by query source", [{"expr": f"sum by (query_source) ({sel(COST, FULL)})", "legend": "{{query_source}}"}],
          unit="currencyUSD", desc="main / subagent / auxiliary")
    b.timeseries("Cost over time (by model)",
                 [{"expr": f"sum by (model) (rate({sel(COST, FULL)}[$__rate_interval]) * $__rate_interval)", "legend": "{{model}}"}],
                 w=12, unit="currencyUSD", draw="bars", fill=80, stack=True, decimals=4, legend_calcs=["sum"])
    b.bargauge("Cost by effort", [{"expr": f"sum by (effort) ({sel(COST, FULL)})", "legend": "{{effort}}"}],
               w=6, unit="currencyUSD", desc="Effort level applied to the request (low/medium/high/xhigh/max).")
    # Cost AND tokens per user/team (Goal 2: tokens with their costs, by user & team)
    b.table("Cost & tokens by user",
            [{"expr": f'topk(15, sum by ("user.email") ({sel(COST, FULL)}))', "instant": True, "refId": "A"},
             {"expr": f'sum by ("user.email") ({sel(TOK, FULL)}) and on ("user.email") topk(15, sum by ("user.email") ({sel(COST, FULL)}))',
              "instant": True, "refId": "B"}],
            w=12, h=8,
            rename={"user.email": "User", "Value #A": "Cost ($)", "Value #B": "Tokens"},
            units={"Cost ($)": "currencyUSD", "Tokens": "short"}, desc="Spend and token volume per user.")
    b.table("Cost & tokens by team",
            [{"expr": f'sum by ("team.id") ({sel(COST, FULL)})', "instant": True, "refId": "A"},
             {"expr": f'sum by ("team.id") ({sel(TOK, FULL)})', "instant": True, "refId": "B"}],
            w=12, h=8,
            rename={"team.id": "Team", "Value #A": "Cost ($)", "Value #B": "Tokens"},
            units={"Cost ($)": "currencyUSD", "Tokens": "short"},
            desc="Populated once clients set team.id in OTEL_RESOURCE_ATTRIBUTES.")
    # Top sessions: cost + tokens, one row per session. refId B is constrained to
    # the same top-25-by-cost sessions as A (via `and on`) so the merge has no
    # token-only blank-cost rows. A session can span models, so model is omitted.
    b.table("Top sessions by cost",
            [{"expr": f'topk(25, sum by ("session.id", "run.mode", "user.email") ({sel(COST, FULL_NS)}))',
              "instant": True, "refId": "A"},
             {"expr": f'sum by ("session.id", "run.mode", "user.email") ({sel(TOK, FULL_NS)}) and on ("session.id") topk(25, sum by ("session.id") ({sel(COST, FULL_NS)}))',
              "instant": True, "refId": "B"}],
            w=24, h=10,
            rename={"session.id": "Session", "run.mode": "Mode", "user.email": "User",
                    "Value #A": "Cost ($)", "Value #B": "Tokens"},
            units={"Cost ($)": "currencyUSD", "Tokens": "short"},
            desc="The 25 most expensive sessions, with their token totals.")

    b.row("Token usage")
    b.timeseries("Token usage by type (stacked)",
                 [{"expr": f"sum by (type) (rate({sel(TOK, FULL)}[$__rate_interval]) * $__rate_interval)", "legend": "{{type}}"}],
                 w=12, draw="bars", fill=80, stack=True, legend_calcs=["sum", "mean", "max"], place="right")
    b.pie("Tokens by model", [{"expr": f"sum by (model) ({sel(TOK, FULL)})", "legend": "{{model}}"}], w=6)
    b.stat("Cache hit ratio",
           [{"expr": f'sum({sel(TOK, FULL, CR)}) / (sum({sel(TOK, FULL, CRCI)}) > 0)'}],
           w=6, unit="percentunit", decimals=1, color="background",
           thresholds={"mode": "absolute", "steps": [{"color": "red", "value": None},
                       {"color": "yellow", "value": 0.3}, {"color": "green", "value": 0.6}]},
           desc="cacheRead / (cacheRead + cacheCreation + input). Higher = more context reuse.")
    b.stat("Input tokens: cached vs fresh",
           [{"expr": f'sum({sel(TOK, FULL, CR)}) or vector(0)', "legend": "cached (read)"},
            {"expr": f'sum({sel(TOK, FULL, FRESH)}) or vector(0)', "legend": "fresh"}],
           w=6, unit="short", decimals=1, text="value_and_name", graph="none",
           desc="Input-side split (output excluded): cacheRead vs input+cacheCreation.")
    b.stat("Cost per 1M tokens",
           [{"expr": f"sum({sel(COST, FULL)}) / (sum({sel(TOK, FULL)}) / 1e6 > 0)"}],
           w=6, unit="currencyUSD", decimals=2, graph="none",
           desc="Blended efficiency: total cost ÷ total tokens. Heavier cache reuse drives this down.")
    b.timeseries("Token burn rate (/min, by type)",
                 [{"expr": f"sum by (type) (rate({sel(TOK, FULL)}[5m])) * 60", "legend": "{{type}}"}],
                 w=18, stack=True, fill=30, place="right")

    b.row("Usage limits (rolling windows)")
    b.gauge("Tokens used in last 5h",
            [{"expr": f"sum(increase({sel(TOK, FULL)}[5h]))"}], w=6, maxvar="$tokens_limit_5h",
            desc="Rolling 5h token usage. Set the 5h token limit variable to match your plan.")
    b.gauge("Tokens used in last 7d",
            [{"expr": f"sum(increase({sel(TOK, FULL)}[7d]))"}], w=6, maxvar="$tokens_limit_weekly",
            desc="Rolling 7d token usage. Set the weekly token limit variable to match your plan.")
    b.stat("Active time per session (avg)",
           [{"expr": f'sum({sel(ACT, BASE)}) / (count(count by ("session.id") ({sel(ACT, BASE)})) > 0)'}],
           w=6, unit="s", desc="Per distinct in-window session (not cumulative session starts).")
    b.pie("Active time by type",
          [{"expr": f"sum by (type) ({sel(ACT, BASE)})", "legend": "{{type}}"}], w=6, unit="s",
          desc="user = keyboard interaction, cli = tool/AI processing.")

    b.row("Sessions & productivity")
    b.pie("Sessions by start type",
          [{"expr": f"sum by (start_type) ({sel(SESS, BASE)})", "legend": "{{start_type}}"}], w=6,
          desc="fresh / resume / continue / agents_view (UI launch).")
    b.timeseries("New sessions over time",
                 [{"expr": f"sum by (start_type) (increase({sel(SESS, BASE)}[$__rate_interval]))", "legend": "{{start_type}}"}],
                 w=10, draw="bars", fill=80, stack=True, decimals=0, legend_calcs=["sum"])
    b.timeseries("Lines of code (added/removed)",
                 [{"expr": f"sum by (type) (increase({sel(LOC, BASE)}[$__rate_interval]))", "legend": "{{type}}"}],
                 w=8, draw="bars", fill=80, decimals=0, legend_calcs=["sum"], place="right",
                 overrides=[{"matcher": {"id": "byName", "options": "removed"},
                             "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "red"}}]},
                            {"matcher": {"id": "byName", "options": "added"},
                             "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "green"}}]}])
    b.pie("Edit decisions (accept/reject)",
          [{"expr": f"sum by (decision) ({sel(EDIT, BASE)})", "legend": "{{decision}}"}], w=6)
    b.bargauge("Edit calls by language",
               [{"expr": f"topk(12, sum by (language) ({sel(EDIT, BASE)}))", "legend": "{{language}}"}],
               w=6, mode="lcd")
    b.bargauge("Cost by skill",
               [{"expr": f'topk(12, sum by ("skill.name") ({sel(COST, FULL)}))', "legend": "{{skill.name}}"}],
               w=6, unit="currencyUSD", desc="Spend attributed to the active skill / slash command.")
    b.bargauge("Cost by subagent",
               [{"expr": f'topk(12, sum by ("agent.name") ({sel(COST, FULL)}))', "legend": "{{agent.name}}"}],
               w=6, unit="currencyUSD", desc="Spend attributed to named subagent types (Explore, Plan, custom, …).")

    b.row("Reliability & events (Loki)")
    def lcount(ev, extra=""):
        return f'sum(count_over_time({LSTREAM} | event_name="{ev}"{extra} [$__range])) or vector(0)'
    b.stat("API requests", [{"expr": lcount("api_request"), "loki": True}], unit="short")
    b.stat("Tool calls", [{"expr": lcount("tool_result"), "loki": True}], unit="short")
    b.stat("Tool failure rate",
           [{"expr": f'sum(count_over_time({LSTREAM} | event_name="tool_result" | success="false" [$__range])) '
                     f'/ (sum(count_over_time({LSTREAM} | event_name="tool_result" [$__range])) > 0)', "loki": True}],
           unit="percentunit", decimals=2, color="background",
           thresholds={"mode": "absolute", "steps": [{"color": "green", "value": None},
                       {"color": "yellow", "value": 0.05}, {"color": "red", "value": 0.15}]})
    b.stat("API errors", [{"expr": lcount("api_error"), "loki": True}], unit="short", color="background",
           thresholds={"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "red", "value": 1}]})
    b.stat("API refusals", [{"expr": lcount("api_refusal"), "loki": True}], unit="short", color="background",
           thresholds={"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "orange", "value": 1}]})
    b.stat("Retries exhausted", [{"expr": lcount("api_retries_exhausted"), "loki": True}], unit="short",
           color="background", thresholds={"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "red", "value": 1}]})
    b.stat("Compactions", [{"expr": lcount("compaction"), "loki": True}], unit="short")
    b.timeseries("Events over time (by type)",
                 [{"expr": f'sum by (event_name) (count_over_time({LSTREAM} | event_name=~"api_request|api_error|api_refusal|tool_result|user_prompt|compaction|api_retries_exhausted" [$__auto]))',
                   "legend": "{{event_name}}", "loki": True}],
                 w=24, draw="bars", fill=70, stack=True, legend_calcs=["sum"], place="right")

    b.row("Latency (Tempo span metrics)")
    def hq(q, span):
        return f'histogram_quantile({q}, sum by (le) (rate(traces_spanmetrics_latency_bucket{{service=~"claude-code.*", span_name="{span}"}}[5m])))'
    b.timeseries("LLM request latency (p50/p95/p99)",
                 [{"expr": hq(0.5, "claude_code.llm_request"), "legend": "p50"},
                  {"expr": hq(0.95, "claude_code.llm_request"), "legend": "p95"},
                  {"expr": hq(0.99, "claude_code.llm_request"), "legend": "p99"}],
                 w=12, unit="s", decimals=2, fill=10, legend_calcs=["mean", "max"], place="right",
                 desc="Computed by Tempo's metrics-generator from claude_code.llm_request spans.")
    b.timeseries("Tool execution latency (p95 by tool)",
                 [{"expr": 'histogram_quantile(0.95, sum by (le, span_name) (rate(traces_spanmetrics_latency_bucket{service=~"claude-code.*", span_name=~"claude_code.tool.*"}[5m])))',
                   "legend": "{{span_name}} p95"}],
                 w=12, unit="s", decimals=2, fill=10, legend_calcs=["mean", "max"], place="right")

    variables = [
        var_ds(), var_ds("loki", "loki", "Loki datasource"),
        var_query("mode", "Mode", COST, '"run.mode"',
                  desc="interactive/automated/workflow. Requires run.mode in OTEL_RESOURCE_ATTRIBUTES "
                       "on every client — including interactive machines (run.mode=interactive). "
                       "Until set, data is untagged and 'interactive' selects nothing."),
        var_query("user", "User", COST, '"user.email"'),
        var_query("model", "Model", COST, "model"),
        var_query("effort", "Effort", COST, "effort"),
        var_query("query_source", "Query source", COST, "query_source"),
        var_query("env", "Env", COST, '"run.env"'),
        var_query("team", "Team", COST, '"team.id"'),
        var_query("session", "Session", COST, '"session.id"', allvalue=".+", hide=0,
                  desc="High-cardinality drilldown. 'All' uses .+ (cheap) rather than enumerating every id."),
        var_const("tokens_limit_5h", "5h token limit", "1000000",
                  "Set to your plan's 5h token cap so the gauge thresholds mean something."),
        var_const("tokens_limit_weekly", "Weekly token limit", "10000000"),
    ]
    return dashboard("claude-code-usage", "Claude Code · Overview", b.panels, variables,
                     "Fleet-wide Claude Code usage: cost, tokens (with/without cache), sessions, "
                     "productivity, reliability events (Loki) and latency (Tempo). Filter by mode, "
                     "user, model, effort, query source, team, env, and session.",
                     ["claude-code", "observability", "ai", "cost"])


# ===========================================================================
# AUTOMATED dashboard — claude -p runs in pods, keyed on run.mode=automated
# ===========================================================================
def build_automated():
    b = Builder()
    A_FULL = ['"run.mode"="automated"', '"run.user"=~"$auser"', '"run.role"=~"$role"',
              '"run.task"=~"$task"', 'model=~"$model"', 'effort=~"$effort"',
              '"team.id"=~"$team"', '"run.env"=~"$env"', '"session.id"=~"$session"']
    A_FULL_NS = [f for f in A_FULL if "session.id" not in f]
    A_BASE = ['"run.mode"="automated"', '"run.user"=~"$auser"', '"run.role"=~"$role"',
              '"run.task"=~"$task"', '"team.id"=~"$team"', '"run.env"=~"$env"', '"session.id"=~"$session"']
    L = '{service_name=~"claude-code.*", session_id=~"$session"} | run_mode="automated"'

    b.text("Populating this dashboard",
           "This view shows **automated** runs (`claude -p` in pods / scripts). It fills in once your "
           "automation sets `OTEL_RESOURCE_ATTRIBUTES` with at least:\n\n"
           "```\nrun.mode=automated,run.role=<coordinator|planner|developer|reviewer|…>,"
           "run.user=<owner>,run.task=<ticket-id>,run.env=<local|ci|prod>\n```\n\n"
           "Set it in the pod spec / launcher. See `components/observability/grafana-dashboards/CLAUDE-CODE-OTEL.md`.",
           h=4)

    b.row("Headline (automated)")
    GREEN = {"mode": "absolute", "steps": [{"color": "green", "value": None},
             {"color": "yellow", "value": 25}, {"color": "red", "value": 100}]}
    b.stat("Cost", [{"expr": f"sum({sel(COST, A_FULL)})", "legend": "USD"}],
           unit="currencyUSD", decimals=2, color="bgsolid", thresholds=GREEN)
    b.stat("Tokens", [{"expr": f"sum({sel(TOK, A_FULL)})"}], unit="short", decimals=1)
    b.stat("Agent sessions", [{"expr": f"sum({sel(SESS, A_BASE)})"}])
    b.stat("Distinct roles", [{"expr": f'count(count by ("run.role") ({sel(COST, A_FULL)})) or vector(0)'}])
    b.stat("Avg cost / session",
           [{"expr": f'sum({sel(COST, A_FULL)}) / (count(count by ("session.id") ({sel(COST, A_FULL)})) > 0)'}],
           unit="currencyUSD", decimals=3, desc="Per distinct in-window session.")
    b.stat("Active time", [{"expr": f"sum({sel(ACT, A_BASE)})"}], unit="s")

    b.row("By role / task / user")
    b.pie("Cost by role", [{"expr": f'sum by ("run.role") ({sel(COST, A_FULL)})', "legend": "{{run.role}}"}],
          w=8, unit="currencyUSD")
    b.pie("Tokens by role", [{"expr": f'sum by ("run.role") ({sel(TOK, A_FULL)})', "legend": "{{run.role}}"}], w=8)
    b.timeseries("Cost over time by role",
                 [{"expr": f'sum by ("run.role") (rate({sel(COST, A_FULL)}[$__rate_interval]) * $__rate_interval)', "legend": "{{run.role}}"}],
                 w=8, unit="currencyUSD", draw="bars", fill=80, stack=True, decimals=4, legend_calcs=["sum"], place="right")
    b.bargauge("Cost by task", [{"expr": f'topk(15, sum by ("run.task") ({sel(COST, A_FULL)}))', "legend": "{{run.task}}"}],
               w=12, unit="currencyUSD")
    b.bargauge("Cost by user", [{"expr": f'topk(15, sum by ("run.user") ({sel(COST, A_FULL)}))', "legend": "{{run.user}}"}],
               w=12, unit="currencyUSD")

    b.row("Sessions & efficiency")
    b.table("Top automated sessions",
            [{"expr": f'topk(25, sum by ("session.id", "run.role", "run.task", "run.user") ({sel(COST, A_FULL_NS)}))',
              "instant": True, "refId": "A"},
             {"expr": f'sum by ("session.id", "run.role", "run.task", "run.user") ({sel(TOK, A_FULL_NS)}) and on ("session.id") topk(25, sum by ("session.id") ({sel(COST, A_FULL_NS)}))',
              "instant": True, "refId": "B"}],
            w=16, h=9,
            rename={"session.id": "Session", "run.role": "Role", "run.task": "Task",
                    "run.user": "User", "Value #A": "Cost ($)", "Value #B": "Tokens"},
            units={"Cost ($)": "currencyUSD", "Tokens": "short"})
    b.stat("Cache hit ratio",
           [{"expr": f'sum({sel(TOK, A_FULL, CR)}) / (sum({sel(TOK, A_FULL, CRCI)}) > 0)'}],
           w=4, h=9, unit="percentunit", decimals=1, color="background",
           thresholds={"mode": "absolute", "steps": [{"color": "red", "value": None},
                       {"color": "yellow", "value": 0.3}, {"color": "green", "value": 0.6}]})
    b.pie("Cost by model", [{"expr": f"sum by (model) ({sel(COST, A_FULL)})", "legend": "{{model}}"}], w=4, h=9, unit="currencyUSD")

    b.row("Reliability (Loki)")
    def lc(ev, extra=""):
        return f'sum(count_over_time({L} | event_name="{ev}"{extra} [$__range])) or vector(0)'
    b.stat("API errors", [{"expr": lc("api_error"), "loki": True}], color="background",
           thresholds={"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "red", "value": 1}]})
    b.stat("API refusals", [{"expr": lc("api_refusal"), "loki": True}], color="background",
           thresholds={"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "orange", "value": 1}]})
    b.stat("Retries exhausted", [{"expr": lc("api_retries_exhausted"), "loki": True}], color="background",
           thresholds={"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "red", "value": 1}]})
    b.stat("Tool failure rate",
           [{"expr": f'sum(count_over_time({L} | event_name="tool_result" | success="false" [$__range])) '
                     f'/ (sum(count_over_time({L} | event_name="tool_result" [$__range])) > 0)', "loki": True}],
           unit="percentunit", decimals=2, color="background",
           thresholds={"mode": "absolute", "steps": [{"color": "green", "value": None},
                       {"color": "yellow", "value": 0.05}, {"color": "red", "value": 0.15}]})
    b.stat("Subagent completions", [{"expr": lc("subagent_completed"), "loki": True}])
    b.timeseries("Errors & refusals over time",
                 [{"expr": f'sum by (event_name) (count_over_time({L} | event_name=~"api_error|api_refusal|api_retries_exhausted" [$__auto]))',
                   "legend": "{{event_name}}", "loki": True}],
                 w=24, draw="bars", fill=70, stack=True, legend_calcs=["sum"], place="right")

    variables = [
        var_ds(), var_ds("loki", "loki", "Loki datasource"),
        var_query("auser", "User", COST, '"run.user"'),
        var_query("role", "Role", COST, '"run.role"'),
        var_query("task", "Task", COST, '"run.task"', allvalue=".+"),
        var_query("model", "Model", COST, "model"),
        var_query("effort", "Effort", COST, "effort"),
        var_query("team", "Team", COST, '"team.id"'),
        var_query("env", "Env", COST, '"run.env"'),
        var_query("session", "Session", COST, '"session.id"', allvalue=".+"),
    ]
    return dashboard("claude-code-automated", "Claude Code · Automated Agents", b.panels, variables,
                     "Automated `claude -p` runs (pods/scripts), keyed on run.mode=automated. "
                     "Segmented by run.role, run.task, run.user. Populates once automation sets "
                     "OTEL_RESOURCE_ATTRIBUTES (see CLAUDE-CODE-OTEL.md).",
                     ["claude-code", "observability", "ai", "automated"])


# ===========================================================================
# WORKFLOWS dashboard — multi-session workflows tagged with wf.id
# ===========================================================================
def build_workflows():
    b = Builder()
    # wf.id=~"$wf" with allValue ".+" restricts to series that actually have a wf.id
    W_FULL = ['"wf.id"=~"$wf"', '"wf.step"=~"$step"', '"run.user"=~"$wuser"',
              'model=~"$model"', 'effort=~"$effort"', '"team.id"=~"$team"',
              '"run.env"=~"$env"', '"session.id"=~"$session"']
    W_FULL_NS = [f for f in W_FULL if "session.id" not in f]
    W_BASE = ['"wf.id"=~"$wf"', '"wf.step"=~"$step"', '"run.user"=~"$wuser"',
              '"team.id"=~"$team"', '"run.env"=~"$env"', '"session.id"=~"$session"']
    L = '{service_name=~"claude-code.*", session_id=~"$session"} | wf_id=~"$wf"'

    b.text("Populating this dashboard",
           "This view shows **workflow** runs — scripts that invoke Claude across multiple sessions, "
           "tagged with a workflow id. It fills in once each session in a workflow sets "
           "`OTEL_RESOURCE_ATTRIBUTES` with:\n\n"
           "```\nrun.mode=workflow,wf.id=<wf_…>,wf.step=<plan|implement|review|…>,run.user=<owner>,run.env=<env>\n```\n\n"
           "Use a stable `wf.id` for all sessions in one workflow run, and `wf.step` to mark the stage. "
           "See `components/observability/grafana-dashboards/CLAUDE-CODE-OTEL.md`.",
           h=4)

    b.row("Headline (workflows)")
    GREEN = {"mode": "absolute", "steps": [{"color": "green", "value": None},
             {"color": "yellow", "value": 25}, {"color": "red", "value": 100}]}
    b.stat("Workflow cost", [{"expr": f"sum({sel(COST, W_FULL)})", "legend": "USD"}],
           unit="currencyUSD", decimals=2, color="bgsolid", thresholds=GREEN)
    b.stat("Tokens", [{"expr": f"sum({sel(TOK, W_FULL)})"}], unit="short", decimals=1)
    b.stat("Workflows", [{"expr": f'count(count by ("wf.id") ({sel(COST, W_FULL)})) or vector(0)'}],
           desc="Distinct wf.id values in range.")
    b.stat("Avg cost / workflow",
           [{"expr": f'sum({sel(COST, W_FULL)}) / (count(count by ("wf.id") ({sel(COST, W_FULL)})) > 0)'}],
           unit="currencyUSD", decimals=3)
    b.stat("Sessions", [{"expr": f"sum({sel(SESS, W_BASE)})"}])
    b.stat("Active time", [{"expr": f"sum({sel(ACT, W_BASE)})"}], unit="s")

    b.row("By workflow")
    b.bargauge("Cost by workflow", [{"expr": f'topk(20, sum by ("wf.id") ({sel(COST, W_FULL)}))', "legend": "{{wf.id}}"}],
               w=12, unit="currencyUSD")
    b.bargauge("Tokens by workflow", [{"expr": f'topk(20, sum by ("wf.id") ({sel(TOK, W_FULL)}))', "legend": "{{wf.id}}"}],
               w=12, unit="short")
    b.timeseries("Cost over time by workflow",
                 [{"expr": f'topk(15, sum by ("wf.id") (rate({sel(COST, W_FULL)}[$__rate_interval]) * $__rate_interval))', "legend": "{{wf.id}}"}],
                 w=24, unit="currencyUSD", draw="bars", fill=80, stack=True, decimals=4, legend_calcs=["sum"], place="right",
                 desc="Top 15 workflows by cost in each interval.")
    b.table("Per-workflow breakdown",
            [{"expr": f'topk(20, sum by ("wf.id", "run.user") ({sel(COST, W_FULL_NS)}))', "instant": True, "refId": "A"},
             {"expr": f'sum by ("wf.id", "run.user") ({sel(TOK, W_FULL_NS)}) and on ("wf.id") topk(20, sum by ("wf.id") ({sel(COST, W_FULL_NS)}))',
              "instant": True, "refId": "B"}],
            w=24, h=9,
            rename={"wf.id": "Workflow", "run.user": "User", "Value #A": "Cost ($)", "Value #B": "Tokens"},
            units={"Cost ($)": "currencyUSD", "Tokens": "short"})

    b.row("By step")
    b.pie("Cost by step", [{"expr": f'sum by ("wf.step") ({sel(COST, W_FULL)})', "legend": "{{wf.step}}"}],
          w=8, unit="currencyUSD")
    b.pie("Tokens by step", [{"expr": f'sum by ("wf.step") ({sel(TOK, W_FULL)})', "legend": "{{wf.step}}"}], w=8)
    b.timeseries("Step cost over time",
                 [{"expr": f'sum by ("wf.step") (rate({sel(COST, W_FULL)}[$__rate_interval]) * $__rate_interval)', "legend": "{{wf.step}}"}],
                 w=8, unit="currencyUSD", draw="bars", fill=80, stack=True, decimals=4, legend_calcs=["sum"], place="right")

    b.row("Efficiency & reliability")
    b.stat("Cache hit ratio",
           [{"expr": f'sum({sel(TOK, W_FULL, CR)}) / (sum({sel(TOK, W_FULL, CRCI)}) > 0)'}],
           w=6, unit="percentunit", decimals=1, color="background",
           thresholds={"mode": "absolute", "steps": [{"color": "red", "value": None},
                       {"color": "yellow", "value": 0.3}, {"color": "green", "value": 0.6}]})
    b.pie("Cost by model", [{"expr": f"sum by (model) ({sel(COST, W_FULL)})", "legend": "{{model}}"}], w=6, unit="currencyUSD")
    b.stat("API errors", [{"expr": f'sum(count_over_time({L} | event_name="api_error" [$__range])) or vector(0)', "loki": True}],
           w=6, color="background",
           thresholds={"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "red", "value": 1}]})
    b.stat("API refusals", [{"expr": f'sum(count_over_time({L} | event_name="api_refusal" [$__range])) or vector(0)', "loki": True}],
           w=6, color="background",
           thresholds={"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "orange", "value": 1}]})

    variables = [
        var_ds(), var_ds("loki", "loki", "Loki datasource"),
        var_query("wf", "Workflow", COST, '"wf.id"', allvalue=".+"),
        var_query("step", "Step", COST, '"wf.step"'),
        var_query("wuser", "User", COST, '"run.user"'),
        var_query("model", "Model", COST, "model"),
        var_query("effort", "Effort", COST, "effort"),
        var_query("team", "Team", COST, '"team.id"'),
        var_query("env", "Env", COST, '"run.env"'),
        var_query("session", "Session", COST, '"session.id"', allvalue=".+"),
    ]
    return dashboard("claude-code-workflows", "Claude Code · Workflows", b.panels, variables,
                     "Multi-session workflow runs tagged with wf.id. Per-workflow and per-step cost, "
                     "tokens, and reliability. Populates once workflow sessions set OTEL_RESOURCE_ATTRIBUTES "
                     "(run.mode=workflow,wf.id=…,wf.step=…). See CLAUDE-CODE-OTEL.md.",
                     ["claude-code", "observability", "ai", "workflow"])


OUT = "/Users/enesanbar/workspace/gitops-flux/components/observability/grafana-dashboards"
for name, d in [("claude-code-dashboard.json", build_overview()),
                ("claude-code-automated.json", build_automated()),
                ("claude-code-workflows.json", build_workflows())]:
    path = f"{OUT}/{name}"
    with open(path, "w") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
    print(f"wrote {path}: {len(d['panels'])} panels, {len(d['templating']['list'])} vars")
