# Dashboard Context

Design for the agent-observability dashboard: what runs are in flight, which
stage each is on, and what the tokens cost. Settled in a grilling session on
2026-09-04; every branch below was chosen deliberately, and the rejected
options are recorded so they are not re-litigated.

Corresponds to **M4** in `TASK_BREAKDOWN.md:413`.

## What already exists

- Phoenix 1.8 + LiveView 1.2 + PubSub + Oban + Postgres are all in the
  supervision tree. The dashboard needs **no new dependency**.
- `reviews`: `pr_id, repo, status, triggered_at, completed_at,
  author_findings, reviewer_findings`. Status is only
  `pending | waiting | complete | failed`.
- Pipeline stages exist **only as log lines** in
  `lib/mewtwo/workers/review_worker.ex`:
  `auth → record → fetch → compress → context → agents → judge → publish`.
  Nothing persists which stage a run is in.
- `Mewtwo.Cost` gives exact token counts from the Bedrock response and USD
  from `BEDROCK_INPUT_USD_PER_MTOK` / `BEDROCK_OUTPUT_USD_PER_MTOK`. The run
  total lands in `author_findings.metadata.usage`.
- Per-agent usage **is computed** in `Mewtwo.Agents.Spawner` (`meta.per_agent`)
  and then **thrown away** — `review_worker.ex:96` merges only
  `agent_meta.usage`.
- No LiveView pages exist. No authentication anywhere in the router.
  `/dev/dashboard` (LiveDashboard) is dev-only.

## Decisions

### 1. Stage state: `stage` column + PubSub

Add `stage` and `stage_started_at` to `reviews`. One helper in the worker
writes the column and broadcasts, called at the 7 existing boundaries.

```elixir
defp stage(review, name) do
  review
  |> Review.changeset(%{stage: name, stage_started_at: DateTime.utc_now()})
  |> Repo.update!()
  |> tap(&PubSub.broadcast(Mewtwo.PubSub, "reviews", {:stage, &1.id, name}))
end
```

~8 extra UPDATEs per run, survives a page reload, no new table.

*Rejected:* a `review_events` table (one row per transition — gives a
per-stage duration waterfall, but new schema and query code); telemetry-only
(nothing persisted, in-flight state lost on restart and invisible to a fresh
page load).

### 2. Agent granularity: live broadcast + persist `per_agent`

The `agents` stage is 5 parallel `Task.async` calls (`spawner.ex:52`) and
dominates run wall-clock, so it cannot stay opaque.

`Spawner` takes `review_id` in opts and broadcasts start/finish per agent —
the LiveView renders a 5-row live checklist. On completion the worker persists
the already-computed `meta.per_agent`:

```diff
   usage: agent_meta.usage,
+  per_agent: agent_meta.per_agent,
```

No write contention: the 5 tasks only broadcast, only the worker writes.

*Rejected:* a `review_agents` table (queryable per-agent SQL, but a new
table); leaving `agents` opaque (the 20–30s that is most of every run stays a
black box and per-agent cost stays unavailable).

### 3. Cost storage: real columns

Add `input_tokens`, `output_tokens`, `calls`, `cost_usd` to `reviews`. The
worker has all four at write time. **Cost is frozen at run time** — rates can
change, so recomputing on read would rewrite history. `cost_usd` is nullable:
NULL means rates were unset. Existing dev rows read NULL; no backfill.

*Rejected:* casting out of `author_findings->'metadata'->'usage'` (no
migration, but every query carries the casting and failed runs have no
metadata at all, so they vanish from cost totals); a daily rollup table (a
live `GROUP BY` is instant at a few dozen runs/day).

### 4. Failure detail: `error` column + per-agent errors

A failed run currently stores `status: "failed"` and nothing else — the reason
lives only in `Logger.error` (`review_worker.ex:391`). Partial failures are
worse: `meta.errors` is never merged into metadata (`review_worker.ex:94`) and
`Spawner.collect_results` discards each agent's error reason
(`spawner.ex:322`).

Add `error :text`, written in `fail/3`. Keep the agent's reason in
`per_agent`, merge `meta.errors` into metadata. The dashboard then shows the
failing stage plus the reason, and marks partial runs where 2 of 5 agents died.

*Rejected:* extending the status vocabulary only (shape of failure without the
why — you still shell into logs for every incident).

### 5. Route and auth: `/dashboard` behind basic auth

The app is deployed publicly (it receives GitHub App webhooks at
`/api/github-app/webhook`) and the dashboard exposes repo names, findings and
spend. One `:admin` pipeline with `Plug.BasicAuth` — no dep, no session, no
user table.

**Credentials are read at runtime**, not via `compile_env`, which would bake
the password into the release at build time. A small function plug reads
`Application.get_env` so the creds come from `runtime.exs` / env.

*Rejected:* mounting under the `dev_routes` block (zero exposure, but you
cannot see production runs — which is where the cost accrues); no auth (only
correct if an authenticating proxy already gates the deploy).

### 6. Layout: one page, inline expand

A single `DashboardLive`: totals strip, queued/running/stalled, then recent
history. Clicking a row expands the per-agent breakdown in place — no new
route, no second mount, no params handling. daisyUI is already installed.

```
─ last 7 days ──────────────────────────────────
 42 runs   $7.31   3.1M in / 180k out   2 failed

QUEUED (18)                    -- from oban_jobs
RUNNING (2)
 acme/web#42   agents    14s   ●●○○●  3/5
 acme/api#7    compress   2s
STALLED (1)
 old/repo#9    agents     2h   job discarded

RECENT
 ▾ acme/web#41  complete  31s  $0.18   7 findings
     bugs     8.1s  12.4k/1.1k  $0.041  3
     perf     6.2s  12.4k/0.6k  $0.032  1
     compress  412k → 98k tokens (76%)  2 files dropped
     context   7 fetched, 3 skipped, 11.2k tokens
     judge     19 raw → 7 author / 4 reviewer, 8 deduped
     publish   posted · review 2841 · 5 inline
   acme/db#3   failed     4s   —       :diff_too_large
```

*Rejected:* split `/runs` and `/costs` (two mounts, two subscription setups,
and a nav for a two-item menu).

### 7. In-flight truth: `oban_job_id` + join `oban_jobs`

`create_review` runs **inside** `perform` (`review_worker.ex:230`), so a run
only appears once a worker picks it up — a burst of 20 labelled PRs shows an
empty dashboard while they sit in the `:reviews` queue. And if the node
restarts mid-run the row stays `pending` forever, showing as "running"
indefinitely.

The worker stores `job.id` (it already has `%Oban.Job{}` in `perform`). The
dashboard left-joins `oban_jobs` for the real state and counts queued jobs
separately. Oban state is the source of truth for **liveness**; the review row
for **what the run was doing**. Zombies self-resolve — a discarded job renders
as dead, not running.

*Rejected:* a staleness heuristic in the view (two lines, but queued runs stay
invisible); an Oban cron reaper (new worker + cron config, and it guesses — a
legitimately slow run gets reaped).

### 8. Refresh: PubSub + 1s local tick

PubSub carries stage and per-agent events. A `:timer.send_interval(1_000, …)`
in `mount` (connected only) advances the elapsed clocks with **no DB hit**.

```elixir
def mount(_, _, socket) do
  if connected?(socket) do
    PubSub.subscribe(Mewtwo.PubSub, "reviews")
    :timer.send_interval(1_000, self(), :tick)
  end

  {:ok, load(socket)}
end
```

PubSub is required by decision 2: per-agent progress lives nowhere but the
broadcast until the run finishes.

*Rejected:* polling the DB every second (deletes the broadcast code, but only
coherent if per-agent progress is persisted, which reopens decision 2 and
forces the `review_agents` table).

### 9. v1 scope

In:

- Totals strip (runs / cost / tokens / failures), run list with current stage,
  per-agent token+cost+latency on expand.
- Cost grouped by repo — the first question anyone asks after seeing a total.
- Per-run pipeline metrics on expand: compression ratio, context
  fetched/skipped, judge dedup count, publish status. All already in the
  metadata map, just unrendered.
- Trend charts: cost/day and a compression-ratio sparkline.

Out: `tool_agreement_rate`. `gitleaks_findings/0` returns `[]` with a warning
(`review_worker.ex:222`) because G1–G3 are not built, so the rate is
**structurally always 0%** — displaying it would show a fake zero. Omit it
entirely until G1–G3 land.

### 10. Charts: server-rendered inline SVG

LiveView computes the points and emits a `<polyline>` / `<rect>` set. No
dependency, no JS hook, no client state; it updates through the normal
LiveView diff.

```heex
<svg viewBox="0 0 240 40" class="w-full h-10">
  <polyline points={@spark} fill="none" stroke="currentColor" stroke-width="1.5"/>
</svg>
```

*Rejected:* Chart.js via esbuild + a hook (real axes and tooltips, but a JS
dep and client/server state to sync for two sparklines); CSS bars (no viewBox
math, but a line trend does not render well as bars).

### 11. Code layout: `Mewtwo.Dashboard` + one test

Queries in one module, `DashboardLive` only renders. The aggregate logic
(windowing, the Oban join, sparkline scaling) is the part that can actually be
wrong, and testing it as plain functions is far cheaper than driving the same
assertions through `LiveViewTest`.

```elixir
test "totals sums tokens and cost over the window" do
  insert_review(cost_usd: 0.10, input_tokens: 1000)
  insert_review(cost_usd: 0.20, input_tokens: 2000)

  assert %{cost: 0.30, input: 3000, runs: 2} = Dashboard.totals(days: 7)
end
```

*Rejected:* queries inline in the LiveView (fewest files, but every assertion
needs LiveViewTest); folding into a context (there is no `Mewtwo.Reviews`
context today — `Mewtwo.Review` is a bare schema the worker queries directly,
so this means a wider refactor than the dashboard needs).

### 12. Window: fixed 7 days, last 25 runs

```elixir
@window_days 7
@recent_limit 25
# ponytail: fixed window; add a period toggle when you actually reach for one
```

*Rejected:* a 24h/7d/30d toggle (~15 lines flowing into every query —
speculative until you compare weeks); all-time (the totals strip becomes a
meaningless lifetime number after a month).

## Work plan

Migration — one file, `reviews` gains `stage`, `stage_started_at`,
`input_tokens`, `output_tokens`, `calls`, `cost_usd`, `error`,
`oban_job_id`, plus an index on `triggered_at`. No new tables, no backfill.

Existing files:

- `lib/mewtwo/workers/review_worker.ex` — `stage/2` helper called at the 7
  boundaries; store `job.id`; write token/cost columns in `complete/7` and
  `error` in `fail/3`; merge `per_agent` **and** `meta.errors` into metadata
  (both dropped today at lines 94–96).
- `lib/mewtwo/agents/spawner.ex` — accept `review_id` in opts, broadcast
  per-agent start/finish, stop discarding agent error reasons (line 322).
- `lib/mewtwo/review.ex` — cast the new fields.
- `lib/mewtwo_web/router.ex` — `:admin` pipeline, `live "/dashboard"`,
  runtime basic auth.

New files:

- `lib/mewtwo/dashboard.ex` — `in_flight/0` (left-joins `oban_jobs`),
  `queued/0`, `recent/1`, `totals/1`, `by_repo/1`, `daily/1`.
- `lib/mewtwo_web/live/dashboard_live.ex` — the page.
- `test/mewtwo/dashboard_test.exs` — aggregate assertions.

## Honesty constraints carried into the UI

- `cost_usd` is NULL when `BEDROCK_*_USD_PER_MTOK` is unset, so **tokens are
  the primary number** and cost renders `—`, never `$0.00`.
- `tool_agreement_rate` is omitted until G1–G3 land.

## Deferred

`review_events` table (per-stage duration waterfall) — add when you want
per-stage history rather than only the current stage. Daily rollups — add when
a live `GROUP BY` gets slow. Period toggle, pagination, agreement metrics.
