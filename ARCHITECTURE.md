# Zacian Architecture — Rewrite Plan

## System Overview

Zacian is a code review agent system that analyzes PRs across multiple specialized agents, coordinates findings through a judge, and posts actionable feedback to GitHub.

**Entry Point:** PR labeled with `need-zacian-review`  
**Exit Point:** Inline comments (author feedback) + summary comment (reviewer risk assessment)

---

## Core Flow

```
GitHub PR Labeled "need-zacian-review"
    ↓
Webhook fires → Handler returns 202 (async)
    ↓
Background Job: Fetch PR diff + context
    ↓
Parallel Agents Run (config-driven, per-repo)
    - Each agent analyzes diff against its domain
    - Returns: {file, line, severity, summary, details, confidence}
    ↓
Judge Coordinator
    - Deduplicates findings
    - Ranks by severity/confidence
    - Splits into: Author Output (actionable) + Reviewer Output (risk)
    ↓
Post to GitHub
    - Author Output: Inline comments on changed lines
    - Reviewer Output: Single summary comment
    ↓
Store in DB: {review_id, pr_id, findings[], timestamp}
```

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
- Validate event (is it `need-zacian-review` label?)
- Enqueue job, return 202
- Handle: attach → start, remove → cancel, code-change → mark-stale

### 2. Job Queue

- Store pending/running reviews
- Track: {review_id, pr_id, status, timestamp, agent_results}
- Trigger parallel agent runs

### 3. Agents (Parallel)

- Each agent: {name, enabled_repos[], prompt, context_files[]}
- Input: diff, repo context, agent-specific CONTEXT.md + rules.md
- Output: structured findings with reasoning
- Run in: subprocess? container? API call?

### 4. Judge Coordinator

- Wait for all agents to finish
- Input: agent findings (unranked)
- Logic:
  - Deduplicate (same line flagged by multiple agents)
  - Rank (severity + confidence)
  - Split (author-actionable vs reviewer-level)
- Output: author_findings[], reviewer_findings[]

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
  author_findings (JSON)
  reviewer_findings (JSON)
}
```

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
   - Fix: Add size check against selected model, reject early if over limit

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

### Phase 1 (Now) — Fix Defects

- [ ] Add payload size guard before Claude calls
- [ ] Raise Judge output limit to ≥16k
- [ ] Add code validation to prevent invented findings
- [ ] Fail fast on diff_too_large (no retries)
- [ ] Post nothing for clean PRs
- [ ] Define severity levels (High/Medium/Low) in prompts
- [ ] Add confidence gate for inline comments

### Phase 2 (v1) — Add Context

- [ ] Feed PR description + commit messages into context
- [ ] Ingest repo docs (README, CONTRIBUTING.md, ADRs, AGENTS.md)
- [ ] Give Reviewer context to Specialist + Judge stages
- [ ] Add severity rubric to findings schema
- [ ] Remove Jira UI references (or implement client)
- [ ] Support GitHub pagination (>100 files)

### Phase 3 (v2) — Impact & Validation

- [ ] Add call graph / reverse dependency analysis
- [ ] Implement deterministic security scanning (Gitleaks/Semgrep)
- [ ] Surface actual test coverage data (not just file presence)
- [ ] Build CODEOWNERS / ownership awareness
- [ ] Implement validation run (tests, linters, scanners)
- [ ] Add cross-repo awareness

---

## Next Steps

1. **Implement Phase 1 defect fixes** — these unblock everything else
2. **Verify context gap improvements** — PR description + docs feed (highest ROI on "flagging intentional code" failures)
3. **Implement severity/confidence gates** — use to drive noise reduction
4. **Decide v1 scope** — v1 or defer, this drives tech decisions for agents and storage
