# Mewtwo Implementation Tasks

## Foundation Layer

### F1: Token Counter Utility
**Depends on:** None
**Files:** `lib/mewtwo/token_counter.ex`
- [ ] Implement token estimation function (approximation: word_count / 1.3)
- [ ] Handle different token weights (code vs. prose)
- [ ] Test with sample diffs (100 bytes → ~30 tokens)

**Acceptance:** Can accurately estimate tokens for a 10KB diff within 10% margin

---

## Phase 1a: Compression Engine

### C1: Line-Level Compression
**Depends on:** F1
**Files:** `lib/mewtwo/compression/line_compressor.ex`
- [ ] Parse unified diff format
- [ ] Extract changed lines with line numbers
- [ ] Keep only 3-line context around changes
- [ ] Discard leading/trailing context from hunks

**Acceptance:** 
- Input: 500-line hunk with 1 change → Output: 7 lines (±2 for heuristic)
- Token reduction: 40-50% on typical hunks

### C2: File Summarization
**Depends on:** C1, F1
**Files:** `lib/mewtwo/compression/file_summarizer.ex`
- [ ] Detect large unchanged sections (>50 lines)
- [ ] Generate one-liner summaries (file name + purpose)
- [ ] Replace sections with `// ... XXX unchanged lines ...`
- [ ] Keep actual changes intact

**Acceptance:**
- 500-line file, 2 changes → compressed to ~20 lines
- Summary captures file intent

### C3: Pattern Grouping
**Depends on:** C2
**Files:** `lib/mewtwo/compression/pattern_grouper.ex`
- [ ] Detect repetitive changes (same pattern, multiple files)
- [ ] Count occurrences (e.g., "10 identical variable renames")
- [ ] Replace with grouped summary
- [ ] Keep one example for clarity

**Acceptance:**
- Input: 10 identical variable renames across files → Output: 1 entry + count

### C4: Compression Orchestrator
**Depends on:** C1, C2, C3, F1
**Files:** `lib/mewtwo/compression.ex`
- [x] Orchestrate stages 1-3 in order
- [x] Estimate tokens before/after
- [ ] ~~Implement priority-based truncation if still over budget~~ **Deferred to Phase 2**
- [x] Emit compression report (original size, compressed size, ratio)

**Acceptance:**
- E2E: 400KB diff → 85K compressed (50-70% reduction)
- Report includes: original_tokens, compressed_tokens, ratio, truncated_sections

**Phase 1a Status:** ✅ COMPLETE (truncation deferred to Phase 2)
- Returns full compressed diff without truncation
- Token budget parameter reserved for Phase 2 truncation logic

---

## Phase 1b: Dynamic Context Fetcher ✅ COMPLETE

### D1: Symbol Parser
**Depends on:** None
**Files:** `lib/mewtwo/context/symbol_parser.ex`
- [x] Parse unified diff to extract changed symbols
- [x] Identify functions (def, defp, fn)
- [x] Identify classes/modules (defmodule)
- [x] Identify imports/dependencies
- [x] Return: `{functions: [...], modules: [...], imports: [...]}`

**Status:** ✅ Complete (9 tests passing)

### D2: Caller Finder
**Depends on:** D1
**Files:** `lib/mewtwo/context/caller_finder.ex`
- [x] For each changed function, grep repo for callers
- [x] Rank by depth: direct callers (depth=1) > transitive (depth=2+)
- [x] Limit to top 10 callers per function (token budget)
- [x] Return: `{function, [{file, line, depth}, ...]}`

**Status:** ✅ Complete (7 tests passing)

### D3: Test File Finder
**Depends on:** D1
**Files:** `lib/mewtwo/context/test_finder.ex`
- [x] Parse changed modules
- [x] Find corresponding test files (e.g., user.ex → user_test.exs)
- [x] Fetch test content (focus on tests for changed functions)
- [x] Return: `{test_file, relevant_test_lines}`

**Status:** ✅ Complete (6 tests passing)

### D4: Config & Docs Finder
**Depends on:** D1
**Files:** `lib/mewtwo/context/config_finder.ex`
- [x] Find config files affected by changes (env vars, feature flags)
- [x] Fetch README, CONTRIBUTING, API docs
- [x] Return: `{config_files: [...], docs: [...]}`

**Status:** ✅ Complete (6 tests passing)

### D5: Dynamic Context Fetcher (Orchestrator)
**Depends on:** D2, D3, D4, F1
**Files:** `lib/mewtwo/dynamic_context.ex`
- [x] Orchestrate symbol parsing + fetching
- [x] Rank all context items by relevance score
- [x] Implement budget-aware fetching (max 15K tokens)
- [x] Emit note: "Fetched X items, skipped Y due to budget"
- [x] Return: `{fetched_context, skipped_items, budget_used}`

**Status:** ✅ Complete (12 tests passing)

**Phase 1b Summary:** All 5 modules implemented with 40 passing tests. Full integration tested.

---

## Phase 1c: Gitleaks Integration

### G1: Gitleaks Runner
**Depends on:** None
**Files:** `lib/mewtwo/gitleaks_runner.ex`
- [ ] Detect if gitleaks binary is installed
- [ ] Spawn gitleaks process with changed files only
- [ ] Capture JSON output
- [ ] Implement retry logic (up to 3 retries on failure)
- [ ] Return: `{:ok, findings}` or `{:error, reason}`

**Acceptance:**
- Correctly detects gitleaks availability
- Runs on sample files, returns valid JSON findings
- Retries on transient failures, gracefully skips on permanent failure

### G2: Gitleaks Parser
**Depends on:** G1
**Files:** `lib/mewtwo/gitleaks_parser.ex`
- [ ] Parse gitleaks JSON output
- [ ] Extract: file, line, secret_type, confidence
- [ ] Normalize to internal format: `%Finding{file, line, type, severity}`
- [ ] Handle edge cases (no findings, malformed output)

**Acceptance:**
- Parse gitleaks JSON → list of findings
- Correctly map secret types to severity (API keys = high, etc.)

### G3: Gitleaks Integration
**Depends on:** G1, G2
**Files:** `lib/mewtwo/gitleaks.ex` (main module)
- [ ] Wrapper that ties runner + parser
- [ ] Supervised execution (catches crashes, gracefully continues)
- [ ] Returns: `%{findings: [], status: :ok|:failed, error: nil|string}`

**Acceptance:**
- E2E: Scan PR → detect secrets (if present) or return empty list
- Never blocks review if gitleaks fails

---

## Phase 2: Agents + Judge

### A1: Agent Findings Schema ✅ COMPLETE
**Depends on:** None
**Files:** `lib/mewtwo/findings/agent_finding.ex`
- [x] Define struct: `%AgentFinding{file, line, severity, confidence, category, message, reasoning}`
- [x] Validate severity ∈ {high, medium, low}
- [x] Validate confidence ∈ {high, medium, low}

**Status:** ✅ Complete (29 tests passing)
- Struct compiles and validates correctly
- All field validations working
- Error handling tested
- 8 severity/confidence combinations validated

### A2: Update Agent Prompts ✅ COMPLETE
**Depends on:** A1, C4, D5, G3
**Files:** 
- `lib/mewtwo/agents/prompts/system_prompt.md` (shared by all agents)
- `lib/mewtwo/agents/prompts/bugs.md`
- `lib/mewtwo/agents/prompts/perf.md`
- `lib/mewtwo/agents/prompts/security.md`
- `lib/mewtwo/agents/prompts/architecture.md`
- `lib/mewtwo/agents/prompts/readability.md`
- `lib/mewtwo/agents/agent_prompts.ex` (module to load/build prompts)

**Status:** ✅ Complete (22 tests passing)
- [x] System prompt: shared instructions, output format, validation rules
- [x] 5 specialized agent prompts (bugs, perf, security, architecture, readability)
- [x] Each prompt includes: what to look for, severity/confidence guides, examples
- [x] Tool agreement scoring explained (Gitleaks match = high confidence)
- [x] Compression note included in all prompts
- [x] agent_prompts module: loads prompts, formats context, builds full prompts
- [x] All prompts embed: compressed diff + dynamic context + gitleaks findings

### A3: Agent Spawner ✅ COMPLETE
**Depends on:** A2
**Files:** 
- `lib/mewtwo/agents/spawner.ex` — spawns agents in parallel
- `lib/mewtwo/bedrock_client.ex` — calls Claude via AWS Bedrock
- Configuration: `.env` + `config/runtime.exs`

**Status:** ✅ Complete (18 tests passing)
- [x] Spawn 5-10 parallel agents using Task.async
- [x] Pass compressed diff + context + gitleaks findings to each
- [x] Collect findings asynchronously
- [x] Return: {:ok, [agent_findings]} or {:ok, findings, errors: []}
- [x] Bedrock client with AWS credential handling
- [x] JSON parsing with AgentFinding validation
- [x] Graceful error handling
- [x] Timeout per agent: 60 seconds (configurable)

### J1: Judge Deduplication
**Depends on:** A1, A3, G2
**Files:** `lib/mewtwo/judge/deduplicator.ex`
- [x] Receive: agent_findings[] + gitleaks_findings[]
- [x] Group by (file, line, category)
- [x] Keep one representative finding per group
- [x] Mark duplicates as "confirmed by N sources"

**Acceptance:**
- Input: 20 findings (5 duplicates) → Output: 15 deduplicated
- Duplicates correctly marked

### J2: Judge Confidence Scorer
**Depends on:** J1
**Files:** `lib/mewtwo/judge/confidence_scorer.ex`
- [x] Implement scoring rule:
  - `high`: LLM + Gitleaks flag same issue
  - `medium`: LLM or Gitleaks only
  - `low`: uncertain findings
- [x] Attach confidence to each finding
- [x] Rank by severity + confidence

**Acceptance:**
- LLM + Gitleaks match (same file+line+category) → high confidence
- LLM only → medium
- Ranking: high severity + high confidence = top priority

### J3: Judge Finding Splitter
**Depends on:** J2
**Files:** `lib/mewtwo/judge/splitter.ex`
- [x] Split findings into two groups:
  - **Author findings**: severity ∈ {high, medium} (actionable)
  - **Reviewer findings**: lower severity/confidence (context for humans)
- [x] Return: `{author_findings, reviewer_findings}`

**Acceptance:**
- High/medium severity → author group
- Low severity or uncertain → reviewer group

### J4: Judge Orchestrator
**Depends on:** J1, J2, J3
**Files:** `lib/mewtwo/judge.ex`
- [x] Orchestrate deduplication → confidence scoring → splitting
- [x] Return: `{author_findings, reviewer_findings, metadata}`
- [x] Metadata: total_agents, gitleaks_findings_count, dedup_count, tool_agreement_rate

**Acceptance:**
- E2E: Receive agent + gitleaks findings → output author + reviewer findings
- Metadata correctly calculated

---

## Phase 3: GitHub Output & Storage

### P1: GitHub Comment Formatter
**Depends on:** J4
**Files:** `lib/mewtwo/github/comment_formatter.ex`
- [ ] Format author findings as inline PR comments
- [ ] Include: file, line, severity, message, confidence badge
- [ ] Keep comment concise (~3 lines per finding)

**Acceptance:**
- Correctly formatted comments, ready to post to GitHub
- Includes severity + confidence info

### P2: GitHub Summary Formatter
**Depends on:** J4
**Files:** `lib/mewtwo/github/summary_formatter.ex`
- [ ] Create summary comment with:
  - Count of findings by severity
  - Tool agreement rate
  - Compression ratio
  - Context fetched vs. skipped
- [ ] Include metadata (tokens used, agents run, gitleaks status)

**Acceptance:**
- Summary includes all required metadata
- Human-readable format

### P3: GitHub Poster
**Depends on:** P1, P2
**Files:** `lib/mewtwo/github/poster.ex`
- [ ] Post inline comments (author findings)
- [ ] Post summary comment
- [ ] Handle GitHub API errors (rate limit, auth, etc.)
- [ ] Return: `{:ok, comment_ids}` or `{:error, reason}`

**Acceptance:**
- Successfully post comments to GitHub PR
- Handle transient failures gracefully

### DB1: Review State Storage
**Depends on:** J4
**Files:** `lib/mewtwo/reviews/review.ex` (update schema)
- [ ] Store: review_id, pr_number, state (pending/complete/stale), findings_count
- [ ] Add: author_findings (JSON), reviewer_findings (JSON)
- [ ] Add: metadata (compression_ratio, token_usage, tool_agreement_rate)

**Acceptance:**
- Schema stores all required fields
- Can retrieve review by PR number

### DB2: Finding Storage
**Depends on:** DB1
**Files:** `lib/mewtwo/findings/finding.ex` (schema)
- [ ] Store individual findings: file, line, severity, confidence, message
- [ ] Link to review_id
- [ ] Add: agent_name, source (agent|gitleaks|both)

**Acceptance:**
- Findings schema compiles and migrates
- Can query findings by review_id

### DB3: Token Usage Storage
**Depends on:** J4, DB1
**Files:** Update DB schema
- [ ] Store: total_tokens, per_agent_tokens, compression_tokens, gitleaks_tokens
- [ ] Link to review_id
- [ ] Add: timestamp

**Acceptance:**
- Token usage correctly recorded per review
- Can query total usage over time

---

## Phase 4: Monitoring & Analytics

### M1: Compression Metrics
**Depends on:** C4, DB3
**Files:** `lib/mewtwo/metrics/compression_metrics.ex`
- [ ] Track: original_size, compressed_size, ratio
- [ ] Emit: "Compression achieved 65%"
- [ ] Store in DB for historical analysis

**Acceptance:**
- Correctly calculates compression ratio
- Stores metrics for trending

### M2: Gitleaks Metrics
**Depends on:** G3, DB3
**Files:** `lib/mewtwo/metrics/gitleaks_metrics.ex`
- [ ] Track: secrets_found, secret_types, false_positive_rate (feedback-based)
- [ ] Emit alerts if > N secrets detected

**Acceptance:**
- Correctly counts secrets by type
- Can track false positive feedback

### M3: Tool Agreement Metrics
**Depends on:** J2, DB3
**Files:** `lib/mewtwo/metrics/agreement_metrics.ex`
- [ ] Track: tool_agreement_rate, high_confidence_findings, medium_confidence_findings
- [ ] Emit: "Tool agreement: 35% of findings verified by both"

**Acceptance:**
- Correctly calculates agreement rate
- Tracks confidence distribution

### M4: Dashboard/Reporting
**Depends on:** M1, M2, M3, DB3
**Files:** `lib/mewtwo_web/live/metrics_live.ex`
- [ ] Show: compression ratio trend, gitleaks findings per day, tool agreement rate
- [ ] Show: review latency, agent performance
- [ ] Real-time updates (LiveView)

**Acceptance:**
- Dashboard displays all metrics
- Refreshes in real-time

---

## Integration & Testing

### I1: Review Pipeline Integration
**Depends on:** C4, D5, G3, A3, J4, P3
**Files:** `lib/mewtwo/review_pipeline.ex`
- [ ] Orchestrate: compression → dynamic context → gitleaks → agents → judge → post
- [ ] Handle errors at each stage (graceful degradation)
- [ ] Emit telemetry events

**Acceptance:**
- E2E: PR labeled → review complete, findings posted
- No stage blocks others; graceful if any fails

### I2: Integration Tests
**Depends on:** All
**Files:** `test/mewtwo/integration/full_review_test.exs`
- [ ] Test E2E flow with sample PR
- [ ] Verify compression, context fetching, gitleaks, agents, judge, posting
- [ ] Mock GitHub API

**Acceptance:**
- Full review pipeline works end-to-end
- All components integrate correctly

### I3: Performance Tests
**Depends on:** All
**Files:** `test/mewtwo/performance/perf_test.exs`
- [ ] Benchmark compression (target: < 5 seconds for 400KB diff)
- [ ] Benchmark context fetching (target: < 10 seconds)
- [ ] Benchmark agent spawning + collection (target: < 120 seconds total)

**Acceptance:**
- All stages complete within target latencies
- No memory leaks (monitor for goroutine/process growth)

---

## Summary by Phase

| Phase | Tasks | Dependencies | Deliverable |
|-------|-------|--------------|-------------|
| Foundation | F1 | None | Token counter |
| 1a | C1-C4 | F1 | Compression engine (50-70% reduction) |
| 1b | D1-D5 | None | Dynamic context fetcher (15K tokens) |
| 1c | G1-G3 | None | Gitleaks wrapper (supervised) |
| 2 | A1-A3, J1-J4 | 1a, 1b, 1c | Agents + Judge (tool agreement scoring) |
| 3 | P1-P3, DB1-DB3 | Phase 2 | GitHub posting + DB storage |
| 4 | M1-M4 | Phase 3 | Monitoring dashboard |
| Integration | I1-I3 | All | E2E pipeline + testing |

---

## Critical Path

```
F1 (Token Counter)
  ↓
C1 → C2 → C3 → C4 (Compression)
           ↓
A1 ← (Agent Finding Schema)
D1 → D2 → D3 → D4 → D5 (Dynamic Context)
           ↓
G1 → G2 → G3 (Gitleaks)
           ↓
A2 → A3 (Agents)
           ↓
J1 → J2 → J3 → J4 (Judge)
           ↓
P1 → P2 → P3 (GitHub Posting)
    ↓
DB1 → DB2 → DB3 (Storage)
    ↓
M1 → M2 → M3 → M4 (Metrics)
    ↓
I1 → I2 → I3 (Integration & Testing)
```

**Estimated Timeline:**
- Foundation: 2 hours
- Phase 1a (Compression): 8-10 hours
- Phase 1b (Dynamic Context): 10-12 hours
- Phase 1c (Gitleaks): 3-4 hours
- Phase 2 (Agents + Judge): 6-8 hours
- Phase 3 (GitHub + DB): 4-6 hours
- Phase 4 (Monitoring): 4-6 hours
- Integration & Testing: 6-8 hours

**Total: ~50-60 hours** (for a skilled Elixir developer)
