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

## Open Questions

- **Agent implementation:** subprocess? container? API? (affects deployment, latency, cost)
- **Agent output schema:** exact fields? validation?
- **Stale review detection:** watch webhook events, or poll PR for commits?
- **Judge deduplication logic:** exact rules for "same finding"?
- **Retry/error handling:** if an agent crashes, cancel review or mark incomplete?
- **Graphify Graph:** still needed for v1, or defer to v2?

---

## Tech Stack (TBD)

- **Language:** (Elixir? Python? Go? Node?)
- **Webhook server:** (Express? Flask? Phoenix? http library?)
- **Job queue:** (Redis? Bull? Sidekiq? In-process?)
- **Database:** (PostgreSQL? SQLite? Firestore?)
- **Agent execution:** (subprocess? Docker? API?)

---

## Next Steps

1. Decide: which open questions need answering before you start building?
2. Lock tech stack
3. Sketch repo file structure
4. Define agent output schema precisely
