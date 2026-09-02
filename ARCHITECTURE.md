# Zacian Architecture — Rewrite Plan

## System Overview

Zacian is a code review agent system that analyzes PRs across multiple specialized agents, coordinates findings through a judge, and posts actionable feedback to GitHub.

**Entry Point:** PR labeled with `initial-review`  
**Exit Point:** Inline comments (author feedback) + summary comment (reviewer risk assessment)

---

## Core Flow (V2)

```
GitHub PR Labeled "initial-review"
    ↓
Webhook fires → Handler returns 202 (async)
    ↓
Background Job: Fetch PR diff + context
    ├─ Fetch changed files, commits, PR metadata
    ├─ Apply COMPRESSION STRATEGY (smart truncation, summarization)
    └─ Apply DYNAMIC CONTEXT (light: callers, tests, configs on-demand)
    ↓
[PARALLEL]
    ├─ Run Gitleaks (secrets detection, supervised with 3 retries)
    │   → findings: {file, line, secret_type}
    │   → status: success | skipped (if retries exhausted)
    │
    └─ Spawn Parallel Agents (5-10, config-driven per-repo)
        Each agent receives:
          - Compressed diff
          - Dynamic context (light)
          - Gitleaks findings (if available)
          - Agent-specific instructions + codebase rules
        → Returns: {findings[], confidence_scores[]}
    ↓
Judge Coordinator
    - Receives: agent_findings + gitleaks_findings
    - Deduplicates findings
    - Scores confidence:
      * LLM + Gitleaks match (file+line+category) → "high"
      * LLM or Gitleaks only → "medium"
    - Ranks by severity/confidence
    - Splits into: Author Output (actionable) + Reviewer Output (risk assessment)
    ↓
Post to GitHub
    - Author Output: Inline comments (high/medium severity only)
    - Reviewer Output: Summary comment (all findings + metadata)
    ↓
Store in DB: {review_id, pr_id, status, token_usage{total, per_agent}}
```

---

## Context Strategy (New)

### Compression Strategy — Intelligent Context Reduction

For large PRs (>50KB diffs or >100 files), apply compression to fit within token budget:

**Techniques:**
- **Line-level diff compression** — collapse unchanged context lines (keep 2-3 lines before/after change)
- **File summarization** — for large files, summarize unchanged sections with comment blocks
- **Pattern grouping** — group similar changes (e.g., 10 identical variable renames) into summaries
- **Smart truncation** — prioritize:
  1. Changed lines (100% inclusion)
  2. Test files (modified tests → high signal)
  3. Configuration changes (immediate impact)
  4. Comments and docstrings (explain intent)
  5. Context (lowest priority, truncate first)

**Token budget:**
- Haiku 4.5: 180K token limit
- Reserve 20K for agent reasoning
- Reserve 10K for findings output
- **Available for context: 150K tokens max**
- Compress if estimated context > 100K

### Dynamic Context — Semantic Context Enrichment

After fetching raw diff, intelligently pull additional context:

**Stage 1: Parse Changed Symbols**
- Extract function/method names, class names, module names from diff
- Identify imports and dependencies

**Stage 2: Fetch Related Context (on-demand)**
- **Function callers** — fetch code that calls modified functions
- **Test files** — fetch test files for modified modules
- **Dependency files** — fetch package.json, go.mod, mix.exs (if changed)
- **Configuration** — fetch env config, feature flags, schema files
- **Documentation** — fetch README, CONTRIBUTING, API docs for context

**Stage 3: Rank by Relevance**
- Direct callers (direct dependencies) → high relevance
- Transitive callers → medium relevance
- Test coverage → high relevance
- Comments in modified code → high relevance
- Import statements → medium relevance

**Budget-aware:** Stop fetching when token budget exhausted. Track what was fetched vs. skipped.

---

## Decisions Locked

| Decision                  | Choice                               | Rationale                                                     |
| ------------------------- | ------------------------------------ | ------------------------------------------------------------- |
| **Lifecycle**             | Full (attach/remove/code-change)     | Handle complete review cycle                                  |
| **Re-attach behavior**    | Refresh existing review              | Don't accumulate stale reviews                                |
| **Webhook behavior**      | Async (fire & forget)                | Keep webhook fast, decouple from pipeline                     |
| **Visibility during run** | None until complete                  | Cleaner history, judge can deduplicate first                  |
| **Output format**         | Inline (author) + comment (reviewer) | Actionable feedback where code is, risk summary for reviewers |
| **Persistence**           | Full findings, no history            | Store author + reviewer findings, drop on refresh             |
| **Agent execution**       | Parallel                             | Faster reviews, concurrent agents                             |
| **Agent selection**       | Per-repo config                      | Reduce cost, cleaner than labels                              |
| **Agent output**          | Structured + reasoning               | TBD: exact schema                                             |

---

## Components to Design

### 1. Webhook Handler

- Listen for GitHub label events
- Validate event (is it `initial-review` label?)
- Enqueue job, return 202
- Handle: attach → start, remove → cancel, code-change → mark-stale

### 2. Job Queue

- Store pending/running reviews
- Track: {review_id, pr_id, status, timestamp, agent_results, context_metadata}
- Trigger parallel agent runs

### 2a. Context Compression Engine

- **Input:** raw diff, changed files, full file contents
- **Processing:**
  - Estimate tokens for each file
  - Apply line-level compression (context window around changes)
  - Apply file summarization for large unchanged sections
  - Group repetitive patterns
- **Output:** compressed diff + metadata (bytes_saved, sections_compressed, sections_skipped)
- **Integration:** runs before agents, fails gracefully if can't compress enough

### 2b. Dynamic Context Fetcher (Light)

- **Input:** changed file list, parsed symbols (functions, classes, modules)
- **Processing:**
  - Query code graph / grep for callers of modified functions
  - Fetch related test files
  - Fetch affected config files (if changed)
  - Budget-aware: prioritize high-signal context, skip if token budget exhausted
- **Output:** enriched context {callers, tests, configs} + token budget used
- **Integration:** runs after compression, respects remaining token budget (target: ~15K)

### 2c. Gitleaks Runner (v2)

- **Input:** PR diff + full file contents
- **Processing:**
  - Run Gitleaks on changed files
  - Extract secret patterns (API keys, credentials, etc.)
  - Supervised execution: retries up to 3 times on failure
  - Graceful degradation: if all retries fail, skip and continue
- **Output:** findings {file, line, secret_type} + run_status (success | skipped)
- **Confidence:** Deterministic detection, high value for Judge scoring
- **Integration:** runs in parallel with agents, completes in <1s

### 3. Agents (Parallel)

- Each agent: {name, enabled_repos[], prompt, context_files[]}
- Input: diff, repo context, agent-specific CONTEXT.md + rules.md
- Output: structured findings with reasoning
- Run in: subprocess? container? API call?

### 4. Judge Coordinator

- Wait for all agents + Gitleaks to finish
- Input: agent_findings[] + gitleaks_findings[]
- Logic:
  - **Deduplicate** (same file+line+category from multiple sources)
  - **Score confidence:** 
    - LLM + Gitleaks match (exact: file+line+category) → "high"
    - LLM or Gitleaks only → "medium"
  - **Rank** by severity + confidence
  - **Split** (author-actionable vs reviewer-level risk)
- Output: author_findings[], reviewer_findings[] + confidence metadata

### 5. GitHub Poster

- Post inline comments (author findings)
- Post summary comment (reviewer findings)
- Handle: update existing review vs fresh post

### 6. Database Schema

```
reviews {
  id (UUID)
  pr_id (int)
  repo (string)
  status (pending | running | complete | cancelled | stale)
  triggered_at
  completed_at
  
  # Findings live in GitHub comments (source of truth)
  # DB stores only operational metrics for cost optimization:
  token_usage {
    total_tokens (int)
    per_agent {
      "bug-finder": 8000,
      "security": 7500,
      "architecture": 6200,
      ...
    }
  }
}
```

**Note:** Findings are posted as comments to GitHub, not stored in DB. GitHub is the source of truth. DB tracks token usage per agent for cost/performance optimization.

### 7. Repo Configuration

- File: `.zacian/config.yml` (or `zacian.yml` at root)
- Content:
  ```yaml
  agents:
    - bugs
    - performance
    - architecture
  ```

---

## Known Defects (Fix Now)

### Critical Path Blockers

1. **Payload size can exceed model context** (Haiku 4.5 = 200K token limit)
   - 400KB diff + 400KB file context ≈ 200–250k tokens
   - No guard check before calling Claude API
   - Fix: **Apply COMPRESSION STRATEGY** before agent runs (not after). Estimate tokens early, compress if needed, emit note to model about what was skipped

2. **Judge output budget is half Reviewer's** (8k vs 16k tokens)
   - Long finding lists truncate mid-tool-call → :no_tool_result
   - Whole review fails and burns retries
   - Fix: Raise Judge's output limit to ≥16k

3. **Findings can be invented by Specialists**
   - verify_category/4 returns model's list wholesale, no enforcement
   - No set-membership check against candidates
   - Fix: Add code validation — length(verified) <= length(candidates), file/line unchanged

4. **:diff_too_large burns retries deterministically**
   - Not a transient failure, but treated as retriable
   - Fix: Fail fast with clear message instead of 3 retry attempts

5. **Missing context is silent**
   - Files truncated by byte cap don't increment counter
   - Model never learns context was withheld
   - Fix: Emit a note to the model when files are skipped

### Information Loss

6. **commit.message fetched then discarded** — free historical signal already paid for
7. **PR title/body/description fetched then discarded** — closest thing to stated intent
8. **Finding deduplication keys on line only** — shifts across rebases re-report as :new
9. **No GitHub pagination** — >100 changed files silently truncated

### Output Quality

10. **Clean PRs get a comment** — "Zacian review — no issues found"
    - Article thesis: "silence is better than noise"
    - Fix: Post nothing when findings list is empty

11. **All findings post as inline comments** — no severity or confidence gate
    - low-confidence notes pollute the PR
    - Fix: Only post high/medium severity inline; low severity in summary only

12. **RISK & BLAST RADIUS counts files with findings, not affected files**
    - Misleading: claims analysis you don't perform
    - Fix: Rename to "Files with Issues" or build actual impact analysis

13. **Jira reference in UI with no client** — review_presenter.ex, reviewer_live.ex
    - Fix: Remove UI reference if no integration planned for v1

---

## Open Questions

- **Agent implementation:** subprocess? container? API? (affects deployment, latency, cost)
- **Agent output schema:** exact fields? validation?
- **Stale review detection:** watch webhook events, or poll PR for commits?
- **Judge deduplication logic:** exact rules for "same finding"?
- **Retry/error handling:** if an agent crashes, cancel review or mark incomplete?
- **Graphify Graph:** still needed for v1, or defer to v2?
- **Impact analysis:** when/how to detect callers, reverse deps, affected services/APIs?
- **RAG/Retrieval:** vector search? embeddings? simple grep + LLM re-rank?
- **Validation run:** Docker container? subprocess? API call to CI system?

---

## Tech Stack (Locked)

- **Language:** Elixir (Phoenix web framework)
- **Webhook server:** Phoenix (Bandit HTTP adapter)
- **Job queue:** TBD (Redis? In-process? Oban?)
- **Database:** PostgreSQL (optional for v1, can mock)
- **Agent execution:** Claude API (no subprocess/container in v1)

---

## Improvements Roadmap

### Phase 1 (V2 Now) — Core Architecture

**Context + Static Analysis**
- [ ] **Implement COMPRESSION STRATEGY** (line-level, file summarization, pattern grouping)
- [ ] **Implement DYNAMIC CONTEXT** (light: callers, tests, configs on-demand) — budget: 15K tokens
- [ ] **Integrate Gitleaks Runner** (secrets detection, supervised with 3 retries, graceful skip)

**Agent + Judge**
- [ ] Spawn parallel agents with: compressed diff + dynamic context + Gitleaks findings
- [ ] Implement Judge confidence scoring: LLM + Gitleaks match → "high", LLM or tool only → "medium"
- [ ] Define severity levels (High/Medium/Low) in prompts + Judge logic
- [ ] Add confidence gate for inline comments (post only high/medium)

**Quality & Output**
- [ ] Post findings as GitHub comments (inline + summary)
- [ ] Don't store findings in DB (GitHub is source of truth)
- [ ] Store token_usage per agent + total in DB
- [ ] Emit note to agents when context was compressed or skipped
- [ ] Post nothing for clean PRs

**Validation**
- [ ] Add payload size guard before Claude calls (use compression, not rejection)
- [ ] Raise Judge output limit to ≥16k tokens
- [ ] Add code validation to prevent invented findings
- [ ] Fail fast on diff_too_large (no retries)

### Phase 2 (V2+1) — Expand Context & Tooling

- [ ] Feed PR description + commit messages into context
- [ ] Ingest repo docs (README, CONTRIBUTING.md, ADRs, AGENTS.md)
- [ ] Support GitHub pagination (>100 files)
- [ ] Add actual test coverage data (not just file presence)

### Phase 3 (V3) — Full Static Analysis + Graph

- [ ] **Add Semgrep** (SAST patterns, custom rules per codebase)
- [ ] **Add language-specific linters** (ESLint, Pylint, etc. — opt-in per repo)
- [ ] **Build Graphify Graph** (code knowledge graph with call analysis, reverse deps)
- [ ] Use graph queries instead of grep for "find callers"
- [ ] Build CODEOWNERS / ownership awareness
- [ ] Implement validation run (CI checks, build status)
- [ ] Add cross-repo awareness

---

## Next Steps

1. **Implement Phase 1 defect fixes** — these unblock everything else
2. **Verify context gap improvements** — PR description + docs feed (highest ROI on "flagging intentional code" failures)
3. **Implement severity/confidence gates** — use to drive noise reduction
4. **Decide v1 scope** — v1 or defer, this drives tech decisions for agents and storage
