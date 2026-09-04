# Codebase Guide

A map of Mewtwo for someone opening it for the first time: what it does, where
execution starts, what each module is responsible for, and — importantly — what
is genuinely built versus still a stub.

Mewtwo reviews GitHub pull requests. You add a label to a PR, five specialised
LLM agents read the diff in parallel, a "judge" merges and scores what they
found, and the result is stored. It is written in Elixir on Phoenix, with Oban
for background jobs and AWS Bedrock for model calls.

> **Related docs.** `ARCHITECTURE.md` is the original design intent,
> `TASK_BREAKDOWN.md` the task list, `CONTEXT_STRATEGY.md` the reasoning behind
> compression and context fetching, and `docs/adr/` the recorded decisions.
> This file describes **the code as it exists today**, which in places differs
> from all of them. Where they disagree, trust this file and the tests.

---

## 1. The one-paragraph version

A GitHub webhook fires when a PR is labelled `initial-review`. The webhook
handler verifies the signature and enqueues an Oban job. That job — the
**ReviewWorker** — is the spine of the whole system: it fetches the PR diff,
compresses it to fit a token budget, optionally gathers surrounding code
context, fans out to five agents in parallel, and hands their findings to the
judge, which deduplicates, scores and splits them into "the author must fix
this" and "a reviewer might want to know this". The result is written to the
`reviews` table and posted to the PR as a single review comment.

---

## 2. End-to-end flow

```
  GitHub PR labelled "initial-review"
              │
              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ MewtwoWeb.Endpoint                                                   │
│   plug :cache_raw_body        ← stashes the unparsed body so the     │
│                                 HMAC signature can be verified       │
└──────────────────────────────────────────────────────────────────────┘
              │  POST /api/github-app/webhook
              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ MewtwoWeb.WebhookController.github_app_webhook/2                     │
│   Mewtwo.GithubApp.verify_webhook_signature/2   (HMAC-SHA256)        │
│   triggers on: action == "labeled" AND label == "initial-review"     │
│             or action == "synchronize" AND that label is present     │
│   → 202 Accepted (or 401)                                            │
└──────────────────────────────────────────────────────────────────────┘
              │  Oban.insert!  (queue: :reviews)
              ▼
╔══════════════════════════════════════════════════════════════════════╗
║ Mewtwo.Workers.ReviewWorker.perform/1        ← START READING HERE    ║
║                                                                      ║
║  :record   insert/resume a Mewtwo.Review row       ✅                ║
║     │                                                                ║
║     ▼                                                                ║
║  :auth     Mewtwo.GithubApp.token_for/2            ✅                ║
║     │        one identity for the whole review — the app if           ║
║     │        configured, else GITHUB_TOKEN                            ║
║     ▼                                                                ║
║  :fetch    Mewtwo.PRContext.fetch_with_diff/2      ✅                ║
║     │        → Mewtwo.GithubClient (REST, retries, status mapping)   ║
║     │        → PR metadata, changed files, commits, unified diff     ║
║     ▼                                                                ║
║  :compress Mewtwo.Compression.compress/3           ✅                ║
║     │        4 stages, ends at a hard token budget                   ║
║     ▼                                                                ║
║  :context  Mewtwo.DynamicContext.fetch/3           ✅ (opt-in)       ║
║     │        callers / tests / config, budget-ranked                 ║
║     │        SKIPPED unless "repo_path" is in the job args           ║
║     ▼                                                                ║
║  :agents   Mewtwo.Agents.Spawner.spawn_agents/5    ✅                ║
║     │        5 parallel Tasks → Bedrock → parsed findings            ║
║     ▼                                                                ║
║  :judge    Mewtwo.Judge.judge/3                    ✅                ║
║     │        dedup → confidence → split                              ║
║     ▼                                                                ║
║  :publish  Mewtwo.Github.Poster.post_review/6      ✅                ║
║     │        one PR review: summary body + inline comments           ║
║     │        gated on :review, :post_to_github                       ║
║     ▼                                                                ║
║  :persist  author_findings / reviewer_findings on the review  ✅     ║
╚══════════════════════════════════════════════════════════════════════╝
```

**Where to start reading:** `lib/mewtwo/workers/review_worker.ex`. Every stage
above is one private function in that file, in the order shown. If you read one
file, read that one.

---

## 3. Directory map

```
lib/mewtwo/
├── workers/review_worker.ex     ★ the spine — orchestrates every stage
│
├── pr_context.ex                  fetch PR metadata + unified diff
├── github_client.ex               GitHub REST: auth, pagination, status mapping
├── github_app.ex                ★ the app's identity: webhook HMAC, JWT,
│   └── github_app/                  installation tokens
│       └── token_cache.ex         hour-long installation tokens, cached
│
├── compression.ex               ★ 4-stage pipeline entry point
│   └── compression/
│       ├── line_compressor.ex     trim each hunk to changed lines ±3 context
│       ├── file_summarizer.ex     collapse long unchanged runs
│       ├── pattern_grouper.ex     group repeated changes across files
│       └── truncator.ex           drop whole files to hit the token budget
│
├── dynamic_context.ex           ★ gather surrounding code, ranked to a budget
│   └── context/
│       ├── symbol_parser.ex       which functions/modules the diff touches
│       ├── caller_finder.ex       who calls them
│       ├── test_finder.ex         which tests cover them
│       └── config_finder.ex       relevant config + docs
│
├── agents/
│   ├── spawner.ex               ★ parallel fan-out, response parsing
│   ├── agent_prompts.ex           assembles the prompt from markdown files
│   ├── prompts/*.md               per-agent instructions + system_prompt.md
│   └── context/*_context.md       per-agent project-specific guidance
│
├── judge.ex                     ★ orchestrates the three judge stages
│   └── judge/
│       ├── deduplicator.ex        merge findings describing one issue
│       ├── confidence_scorer.ex   score from corroboration, then rank
│       └── splitter.ex            author-actionable vs reviewer-context
│
├── github/
│   ├── finding_grouper.ex         collapse one issue reported per file
│   ├── comment_formatter.ex       findings → inline review comments
│   ├── summary_formatter.ex       the run's summary comment
│   └── poster.ex                ★ publishes the review to the PR
│
├── findings/agent_finding.ex      the finding struct + validation
├── bedrock_client.ex              the only place that calls a model
├── cost.ex                        token accounting and cost estimation
├── token_counter.ex               token estimation (heuristic, not a tokenizer)
└── review.ex                      Ecto schema for the `reviews` table
```

Everything under `lib/mewtwo_web/` is stock Phoenix scaffolding except
`controllers/webhook_controller.ex` and the `cache_raw_body` plug in
`endpoint.ex`. There is no UI.

---

## 4. The stages in detail

### 4.1 Ingress — webhook

`lib/mewtwo_web/controllers/webhook_controller.ex`

Signature verification needs the *raw* request body, but Phoenix parses and
discards it. `endpoint.ex` therefore installs a `cache_raw_body` plug that
stashes the untouched body in `conn.private[:raw_body]` before parsing. If you
ever see signature checks failing for no reason, that plug is the first place
to look.

The handler enqueues and returns `202` immediately — no review work happens in
the request cycle.

### 4.2 Fetch — `PRContext` + `GithubClient`

`PRContext.fetch_with_diff/2` makes four API calls: PR, files, commits, and the
diff itself. The diff needs `Accept: application/vnd.github.v3.diff`; the
default JSON media type returns the PR object instead.

`GithubClient` is a thin but opinionated wrapper:

- **Three ways to authenticate**, in order: a `:token` option (a GitHub App
  installation token or JWT, sent as `Bearer`), `GITHUB_TOKEN` (sent as
  `token`), or nothing at all — enough for public repos at 60 requests/hour.
  The scheme matters: GitHub accepts `Bearer` for both kinds of credential but
  rejects `token` for a JWT. Sending an empty `token ` value gets a hard 401
  instead of being treated as anonymous, so the header is omitted rather than
  blanked.
- **Non-2xx is an error.** GitHub returns 401/403/404 with a normal-looking
  JSON body; without an explicit status check those flow downstream as success.
  Errors are mapped to `{:not_found, msg}`, `{:unauthorized, msg}`,
  `{:rate_limited, msg, seconds}` or `{:http_error, status, msg}`.
- **Pagination is capped** at 10 pages by default. Pointed at a listing
  endpoint, an uncapped `Link: rel="next"` follow will walk a repository's
  entire history and exhaust the hourly quota in a single call.
- **Writes need a token.** `post/3` shares the same status mapping;
  `authenticated?/0` lets a caller report a missing token as such instead of
  passing GitHub's 401 downstream.

### 4.2b Identity — `GithubApp`

A review is posted **by the app**, not by whoever's personal token is in the
environment. A review from a human account is indistinguishable from that
human's own review — their avatar, their name, their rate limit.

Acting as the app is two hops, both in `GithubApp`:

```
GITHUB_APP_ID + private key (RS256)
        │  Joken, iss=app_id, exp ≤ 10 min
        ▼
   app JWT ──► POST /app/installations/:id/access_tokens
                        │
                        ▼
            installation token (1 hour) ──► reads the PR, posts the review
```

- **The JWT cannot touch a repository.** It only reads app-level endpoints;
  everything else needs an installation token minted with it.
- **`exp` must be within 10 minutes** and `iat` is back-dated 60s, per
  GitHub's guidance, or a slow clock gets a 401.
- **The installation is resolved once.** Webhook payloads carry
  `installation.id`, so `WebhookController` passes it into the job args and no
  lookup is needed. Without it, `GET /repos/:repo/installation` finds it.
- **Tokens are cached** in `GithubApp.TokenCache` (an `Agent`) until five
  minutes before expiry, so a review's five-odd requests share one mint. A
  missing cache process is not fatal — it just means minting again.
- **`.env` writes values as `KEY = value`**, so every read is trimmed. A
  leading space in the app id signs a JWT with `iss: " 123"` and GitHub
  answers with an unhelpful 401.

`ReviewWorker` resolves the identity in its `:auth` stage before spending any
model calls, and threads it through both `PRContext` and `Poster` — so reads
and writes are the same actor. With no app configured, everything falls back
to `GITHUB_TOKEN` with a warning that says who the comments will come from.

Current app: `mewvi` (id 4802140), with `pull_requests: write` — the one
permission the poster needs.

### 4.3 Compress — `Compression`

Four stages, in order, ending at a hard budget:

| Stage | Module | What it does |
|---|---|---|
| 1 | `LineCompressor` | Keeps changed lines ±3 context; file headers pass through untouched |
| 2 | `FileSummarizer` | Collapses unchanged runs **over 50 lines** into a marker |
| 3 | `PatternGrouper` | Groups repeated changes across files |
| 4 | `Truncator` | Drops whole files until the diff fits `diff_token_budget` |

Two invariants worth knowing, because both were violated by earlier versions
and both are now covered by regression tests:

1. **`@@` hunk headers must survive.** They are the only source of line numbers
   in a unified diff. Strip them and agents have no way to report a real
   `line`, so they invent one — and every downstream consumer, including the
   judge's `{file, line, category}` grouping, silently breaks.
2. **Short context runs must survive.** Without surrounding lines a function
   body reads as truncated, which reliably produces hallucinated "missing
   `end`" and misread-return findings.

`Truncator` drops in ascending review value — generated/vendored (lockfiles,
`dist/`, `.min.js`) → assets → snapshots → tests → source — and within a tier
the largest file first, so each drop buys back the most budget. It prepends a
marker naming what was omitted, so agents know the picture is incomplete rather
than assuming they can see the whole change.

### 4.4 Context — `DynamicContext`

Parses which symbols the diff touches, then finds their callers, tests, and
relevant config/docs, ranks them by relevance, and fills a token budget
(default 15,000).

**This stage greps the local filesystem**, so it needs a checkout. A webhook
job has none, so it is skipped unless `"repo_path"` is passed in the job args.
When skipped, agents see the diff alone — noticeably weaker reviews, and the
log says so explicitly.

### 4.5 Agents — `Spawner`

Five agents (`bugs`, `perf`, `security`, `architecture`, `readability`) run as
parallel `Task`s, each a single Bedrock call. Prompts are assembled by
`AgentPrompts.build_prompt/4` from markdown on disk:

```
system_prompt.md  +  prompts/<agent>.md  +  context/<agent>_context.md
                  +  compressed diff  +  dynamic context  +  tool findings
```

Editing agent behaviour means editing those markdown files, not Elixir.

Two things in `Spawner` exist because of real failures:

- **Pre-flight token check.** The prompt is measured before the call. Over the
  limit, the agent is skipped without spending a request — otherwise an
  oversized diff buys five identical HTTP 400s and no review.
- **Tolerant JSON extraction.** `parse_findings/2` tries the raw response, then
  fenced code blocks, then the first balanced `[...]`/`{...}` span, tracking
  string state so a bracket inside a JSON string does not end the span early.
  Models routinely wrap output in a ```json fence; a bare `Jason.decode/1`
  silently drops every finding. An unparseable response logs a warning, so
  "failed to parse" stays distinguishable from "found nothing".

Returns `{:ok, findings, meta}` where `meta` carries `usage`, `errors` and
`per_agent` stats. A partial failure is still a review; only an all-agents-fail
run is an error.

### 4.6 Judge — `Judge` + three stages

```
raw findings ──► Deduplicator ──► ConfidenceScorer ──► Splitter ──► {author, reviewer}
                 group by            score from            severity +
                 {file,line,         corroboration         confidence
                  category}
```

**`Deduplicator`** groups on `{file, line, category}` and keeps one
representative per group (most severe → most confident → fullest reasoning),
recording every distinct source on it. A Gitleaks finding with no matching
agent finding survives on its own: a secret nobody's agent noticed still
matters.

**`ConfidenceScorer`** assigns confidence from corroboration:

| Confidence | When |
|---|---|
| `:high` | A tool **and** an agent independently flagged it |
| `:medium` | Agents only, or the tool only |
| `:low` | A lone agent that was itself unsure |

A single agent claiming `:high` still scores `:medium`. Self-reported
confidence is only trusted *downwards* — otherwise every agent self-certifies
into the top tier and tool agreement means nothing.

**`Splitter`** sends `high`/`medium` severity to the author, *unless*
confidence is `:low`. A high-severity/low-confidence finding goes to reviewers
on purpose: telling an author to fix something we are not sure about is the
fastest way to lose their trust in the bot.

`Judge.judge/3` returns `{author, reviewer, metadata}`. Pass `:total_agents`
explicitly when you know it — inferred from findings, it undercounts any agent
that ran and found nothing.

### 4.7 Publish — `Github.Poster` + two formatters

```
{author, reviewer, metadata}
        │
        ▼
  FindingGrouper ──► patterns ───► SummaryFormatter ──► review body
        └──────────► individual ─► CommentFormatter ──► inline comments
                                          │
                                          ▼
                       POST /repos/:repo/pulls/:n/reviews
```

One request, not N. A single **pull request review** carries the summary as its
body and every author finding as an inline comment, so the author gets one
notification and the post cannot land half-finished.

- **Posted as the app**, with the installation token from the `:auth` stage.
  If the app is configured but its token cannot be minted, publishing errors
  rather than quietly posting as a person — see §4.2b.
- **`event: "COMMENT"`, never `REQUEST_CHANGES`.** A bot that blocks merges on
  unverified model output has its permissions revoked within a week.
- **Inline comments merge per `{file, line}`.** The judge groups on
  `{file, line, category}`, so `bugs` and `security` on one line survive as two
  findings; posted separately they read as the bot repeating itself.
- **A recurring issue is one entry, not N comments.** `FindingGrouper` clusters
  findings in the same category whose messages overlap by ≥70% (Jaccard on
  words, so "…to portfolio data" and "…to portfolio data layer" are one issue)
  and promotes a cluster of 3+ to a *pattern*. Patterns cannot be inline —
  they span files — so they go in the summary with every location listed. This
  is measured, not theoretical: one real run produced five "remove cross-module
  dependency from bookfolio to portfolio data" findings and three "remove
  unused `props` parameter" ones, which was 7 inline comments where 2 plus one
  summary entry says more. Two occurrences stay individual: a comment on the
  exact line beats a summary entry, and twice is a coincidence.
- **422 is retried once.** GitHub rejects a comment on a line outside the diff
  — and rejects the *whole review* when it does. Agents do occasionally report
  a line just past a hunk, so the retry folds the inline comments into the
  summary body. A slightly worse review beats a review nobody sees.
- **Reviewer findings live in the summary** behind a `<details>`, capped at 12.
  They are context, not a task list.
- **A publish failure does not fail the job.** The findings are already stored
  and producing them cost five model calls; retrying to fix a comment re-runs
  all of it, and a 403 from a missing `pull_requests: write` scope will fail
  again anyway. The outcome is recorded on the review as
  `author_findings["metadata"]["publish"]`.

Gated on `:review, :post_to_github` (default true, forced off in `test.exs`)
and overridable per job with `"publish" => false`.

### 4.8 Persist

Findings are written to the `reviews` row as JSON via `AgentFinding.to_map/1`.
Judge metadata, token usage, compression and context counts, and the publish
outcome all ride inside `author_findings["metadata"]`; a dedicated column would
be cleaner but needs a migration.

```elixir
Mewtwo.Repo.all(Mewtwo.Review) |> List.last() |> Map.get(:author_findings)
```

---

## 5. Cross-cutting concerns

### Model calls — `BedrockClient`

The single place anything talks to a model. Uses a Bedrock **API key** (an
`ABSK...` bearer token), not SigV4. Three details that are easy to get wrong
and each cost a debugging session:

| Detail | Correct value | Wrong value's symptom |
|---|---|---|
| Host | `bedrock-runtime.{region}` | `bedrock.` → `UnknownOperationException` |
| API version | `bedrock-2023-05-31` | Anything else → `400 Invalid API version` |
| Model ID | full inference profile, e.g. `us.anthropic.claude-opus-4-5-20251101-v1:0` | bare name → `400` or "on-demand not supported" |

Returns `{:ok, text, usage}` — usage flows up through `Spawner` to the worker.

### Cost — `Cost`

Token counts come from Bedrock's response and are exact. **Prices are not
hardcoded**: Bedrock is partner-operated and priced separately from Anthropic's
first-party API, so rates are configuration:

```
BEDROCK_INPUT_USD_PER_MTOK=
BEDROCK_OUTPUT_USD_PER_MTOK=
```

Unset, you get exact token counts and `cost unavailable` rather than a
confident wrong number.

### Retries — Oban

`ReviewWorker` runs with `max_attempts: 3`.

- **Permanent** (`:not_found`, `:unauthorized`, `:diff_too_large`,
  `:unexpected_diff_body`) → `{:cancel, reason}`. A 401 will still be a 401 on
  attempt three.
- **Rate limited** → `{:snooze, seconds}` read from `retry-after` or
  `x-ratelimit-reset`. Default backoff would spend all three attempts inside
  the same window.
- **Everything else** → `{:error, reason}`, normal retry.

A retried job **reuses** the existing `pending`/`waiting` review row rather
than inserting a duplicate.

### Logging

Every stage logs entry and exit with timings, sizes and token counts, prefixed
by stage: `[review]`, `[pr]`, `[compression]`, `[context]`, `[agents]`,
`[agent <name>]`, `[bedrock]`, `[judge]`, `[github_app]`, `[publish]`. Each agent logs its findings one per
line; the judge logs its decisions and the final author/reviewer lists with
`confirmed by` provenance. `--log-level debug` adds per-compression-stage
deltas and per-finding reasoning.

### Configuration

| Key | Where | Purpose |
|---|---|---|
| `:review, :diff_token_budget` | `config/config.exs` | Ceiling on the compressed diff (default 100k) |
| `:review, :max_prompt_tokens` | `config/config.exs` | Per-agent pre-flight ceiling (default 180k) |
| `:review, :post_to_github` | `config/config.exs` | Whether to comment on the PR (default true, off in test) |
| `GITHUB_APP_ID`, `GITHUB_PRIVATE_KEY_PATH` | `.env` | The app the review is posted as. `GITHUB_PRIVATE_KEY` takes the PEM inline instead |
| `:bedrock` | `config/runtime.exs` | Token, model ID, region |
| `:bedrock_pricing` | `config/runtime.exs` | Per-MTok rates for cost reporting |
| `Oban, queues` | `config/config.exs` | Must include `reviews:` or jobs never run |

`.env` is loaded automatically by the `:dotenv` dependency.

---

## 6. What is built, and what is not

Verified against the code and its tests, not against the task list.

### Built and tested

| Area | Modules | Notes |
|---|---|---|
| Webhook ingress | `webhook_controller`, `github_app` | Label trigger works end to end |
| App auth | `github_app`, `github_app/token_cache` | JWT + installation tokens, cached; reviews are authored by the app |
| GitHub API | `github_client`, `pr_context` | App/PAT/anonymous auth, status mapping, page cap |
| Compression | `compression` + 4 stages | Including budget truncation |
| Dynamic context | `dynamic_context` + 4 finders | Needs a local checkout |
| Agents | `spawner`, `agent_prompts`, 6 prompt files | 5 agents, parallel |
| Model calls | `bedrock_client` | Opus 4.5 via Bedrock API key |
| Judge | `judge` + 3 stages | J1–J4 complete |
| Cost | `cost` | Exact tokens; prices need configuring |
| GitHub output | `github/finding_grouper`, `github/comment_formatter`, `github/summary_formatter`, `github/poster` | P1–P3 complete; one review per PR |
| Persistence | `review` schema | Findings + metadata as JSON |

### Not built

| Gap | Impact |
|---|---|
| **Gitleaks** (`gitleaks_runner`, `gitleaks_parser`, `gitleaks`) | No finding can reach `:high` confidence — that tier *requires* an agent and a tool agreeing. Every real run reports `tool_agreement_rate: 0.0`. The judge handles this cleanly, but its central scoring rule is inert until this lands. |
| **Metrics** (`compression_metrics`, `agreement_metrics`, dashboard) | No visibility beyond logs. |
| **Integration tests** | Every stage is unit-tested; nothing tests them wired together. |

### Known rough edges

- **`TASK_BREAKDOWN.md` checkboxes are stale.** `F1` and `C1`–`C3` are marked
  TODO but the modules exist and are tested. Trust the code.
- **`DynamicContext` needs a checkout**, so webhook-driven reviews currently
  run without caller/test context. Shallow-cloning the PR head is the natural
  fix.
- **Cross-category duplicates are not merged.** Grouping includes `category`,
  so `bugs` and `security` flagging the same line produce two findings. Per
  spec; `CommentFormatter` merges them into one comment so the author does not
  see the same line commented twice, but they are still two findings on the
  record.
- **`diff_token_budget: 100_000` is expensive** — every agent gets the full
  diff, so five agents is up to 500k input tokens per review.
- **Truncation is persisted but the diff is not.** Dropped files are recorded
  in `metadata.compression` and named in the summary comment, but the
  compressed diff the agents actually saw is not kept.
- **Publishing is not idempotent.** Re-running a review for the same PR posts a
  second review; nothing looks for one already posted. Re-review on
  `synchronize` is exactly that case, so pushing to a labelled PR accumulates
  review comments.

---

## 7. Running it

```bash
mix deps.get
mix ecto.setup
mix test                 # ~417 tests, no network calls except a few GitHub 401s
iex -S mix phx.server
```

Trigger a review without a webhook or a tunnel:

```elixir
%{"pr_id" => 1, "repo" => "owner/name", "pr_number" => 42,
  "agents" => ["bugs"],                   # cheaper than the default five
  "repo_path" => "/path/to/local/clone",  # omit to skip dynamic context
  "publish" => false}                     # omit to comment on the real PR
|> Mewtwo.Workers.ReviewWorker.new()
|> Oban.insert!()
```

Required in `.env`: `BEDROCK_TOKEN`, `BEDROCK_MODEL_ID`. To post the review as
the app: `GITHUB_APP_ID` and `GITHUB_PRIVATE_KEY_PATH`, with the app installed
on the repository. `GITHUB_TOKEN` is the fallback when no app is configured —
it works, but the comments come from that account.

`mix test` deletes the app variables in `test_helper.exs`, so no test can mint
a real installation token; the app-auth tests generate their own key.

---

## 8. Suggested reading order

1. `lib/mewtwo/workers/review_worker.ex` — the whole flow in one file
2. `lib/mewtwo/agents/spawner.ex` and `agents/prompts/system_prompt.md` — what
   an agent actually receives and returns
3. `lib/mewtwo/judge.ex` and its three stages — how raw findings become a review
4. `lib/mewtwo/compression.ex` and `compression/truncator.ex` — how a large PR
   is made to fit
5. `test/mewtwo/judge/` and `test/mewtwo/compression/` — the tests document the
   edge cases more precisely than any prose here
