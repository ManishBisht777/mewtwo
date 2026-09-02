# Code Review Agent System — Domain Language

## Context Management

### Compression Strategy

A set of techniques to fit large PRs into token budgets without losing signal:

1. **Line-level compression** — only include 2-3 lines of unchanged context around changes
2. **File summarization** — replace large unchanged sections with summaries
3. **Pattern grouping** — consolidate repetitive changes (e.g., "10 variable renames in file X")
4. **Priority-based truncation** — keep changes first, then tests, then config, then documentation

**Goal:** Reduce diff size 50-80% while preserving all signal needed for analysis.

### Dynamic Context

Additional context fetched *after* parsing the diff, based on what changed:

- **Code dependencies** — fetch files that import/call the modified code
- **Test coverage** — fetch test files for modified modules
- **Configuration** — fetch env configs, feature flags affected by changes
- **Documentation** — fetch READMEs and API docs related to changed modules

**Goal:** Give agents the *right* context (not just more context). A caller of modified function is more valuable than 50 lines of unrelated code.

---

## Core Concepts

### Pull Request (PR)

A proposed code change to a GitHub repository. PRs contain a diff, metadata (files changed, lines added/removed), and linked context (related issues, previous commits).

### Code Review / Review

An automated analysis of a PR's changes, triggered by label attachment. Produces two outputs:

1. **Author Output** — actionable feedback for the code author ("here's what to fix")
2. **Reviewer Output** — risk assessment for human reviewers ("here's what you need to know about impact and uncertainty")

### Review Trigger

Label attachment to a PR. Only labeled PRs enter the review pipeline. Attachment happens manually (developer or maintainer decision), not automatically on PR open.

### Review States

- **Pending** — review in progress (agents running)
- **Complete** — review finished, outputs posted to GitHub
- **Stale** — PR's code changed after review was complete; review flagged as outdated but not auto-rerun

Code changes to a PR mark an existing review as stale. A stale review requires manual re-trigger (re-attach label) to refresh.

### Agent

A specialized analyzer that evaluates a PR against one dimension (e.g., bugs, performance, architecture). Each agent:

- Receives a common analysis context (diff, docs, dependencies, code graph)
- Calls Claude API with its own system prompt (including codebase-specific rules and context)
- Returns findings with confidence scores
- Gets rated independently by reviewers (feedback loop)

### Judge Agent

A coordinator agent that receives findings from all specialized agents and static analysis tools, producing the two final outputs. 

**Responsibilities:**
- Deduplicates findings (same file+line+category from multiple sources)
- Scores confidence using tool agreement: LLM + deterministic tool match → "high", LLM or tool only → "medium"
- Ranks by severity + confidence
- Splits into: author-actionable (high/medium) vs. reviewer-level risk (lower confidence)

### Golden PR

An exemplary PR used as a few-shot reference in agent system prompts. Shows agents the depth and style of analysis desired. Selected manually by the team.

### Feedback Loop

Mechanism for reviewers to rate individual agent outputs (👍 helpful, 👎 missed something, etc.). Feedback is stored and used to guide manual prompt iteration and improvement.

### CONTEXT.md (per-agent)

Codebase-specific context for a specialized agent. Contains:

- Tech stack details relevant to that agent's domain
- Architecture patterns that exist in the codebase
- Known risks or bottlenecks
- Conventions and anti-patterns

Kept in agent-specific files (not this global CONTEXT.md). Example: `agents/architecture/CONTEXT.md`.

### rules.md (per-agent)

Codebase-specific rules for a specialized agent. Contains:

- Style rules and thresholds ("functions >50 lines = red flag")
- Severity mappings ("missing test = medium, security issue = high")
- Domain-specific checks ("flag manual DI instantiation in this codebase")

### Graphify Graph

A queryable code knowledge graph representing the codebase:

- Nodes: modules, functions, classes, imports, dependencies
- Edges: imports, function calls, inheritance, data flow
- Confidence tags: "EXTRACTED" (explicit in source) vs. "INFERRED" (derived)

Pre-computed once per deployment, updated incrementally on PR merge (only affected areas) or manually triggered. Agents query this graph instead of grepping files.

### Ponytail Rules

A decision ladder injected into agent system prompts to enforce minimalist code practices:

1. Does this need to exist? (YAGNI)
2. Already in this codebase?
3. Available in standard library?
4. Native platform feature?
5. Installed dependency?
6. Can it be one line?
7. Only then: write code

Reduces generated code and token usage (~22% savings).

### Confidence Score

Categorical confidence ("high", "medium", "low") attached to each finding. Used by judge to rank findings and gate posting to GitHub.

**Scoring rules (v2):**
- **High confidence:** LLM agent + Gitleaks independently flag the same issue (file+line+category match)
- **Medium confidence:** LLM agent *or* Gitleaks flags it, but not both
- **Low confidence:** Very uncertain; typically not posted inline, only in reviewer summary

### Gitleaks

Deterministic secrets scanner. Detects API keys, credentials, tokens in code.

**v2 Role:** Only static analysis tool included in v2 (Semgrep deferred to v3). Runs in parallel with agents. Findings feed into Judge's confidence scoring.

**Integration:** Supervised execution — retries up to 3 times on failure. If all retries fail, skips gracefully (doesn't block review).

### Tool Agreement

When LLM agents and static analysis tools independently flag the same issue (exact match: file + line + issue category), it increases confidence that the finding is real (not a hallucination or false positive).

**Example:** Gitleaks detects hardcoded API key at line 42 of config.py. Security agent also flags it. → **High confidence** (tool + LLM agree).

## Relationships

- One PR → one review (at a time; stale reviews are replaced, not accumulated)
- One review → multiple agents (5+ core agents, expanding to 10+)
- One review → two outputs (author-facing and reviewer-facing)
- All agents → one judge agent → two outputs
- Each agent → independent feedback loop and iterative improvement

---

## Quality & Safety Principles

### Noise Posture (Critical)

**Core Thesis:** Silence is better than noise. Precision over exhaustiveness.

- **No comment for clean PRs** — if there are no issues, post nothing
- **Bias toward fewer findings** — report only high-confidence, actionable issues
- **Severity floor for inline comments** — only high/medium severity gets posted to code
- **Findings cap** — implement a reasonable limit to prevent reviewer fatigue
- **Confidence gates** — low-confidence findings don't post inline

**Current State:** Violated. Clean PRs get "Zacian review — no issues found" comment. Every finding is reported regardless of severity/confidence.

### Safety Boundary (Inviolable)

- **No automatic approvals** — event type is "COMMENT" only (never "APPROVE" or "REQUEST_CHANGES")
- **No commit status mutations** — no green checks, no blocking status on failures
- **Read-only to GitHub** — write access is exactly: post comment, update comment (2 endpoints)
- **Cannot manufacture a false signal** — a developer cannot merge based on Zacian

### Context Gap (Highest Priority)

Zacian misses critical inputs:

1. **Architectural Intent** — No ADRs, design docs, AGENTS.md, README, CONTRIBUTING.md
   - Fix: ingest repo-resident docs via fetch_file path
   - Payoff: directly reduces "flagging intentional design decisions" failures
   
2. **Historical Context** — PR bodies, commit messages, review discussion are fetched then discarded
   - Fix: retain commit.message and PR descriptions in context
   - Payoff: "why this workaround exists" becomes visible
   
3. **Repository Awareness** — Only changed files, no callers, no importers, no tests, no call graph, no CODEOWNERS
   - Fix: defer to v2 (needs retrieval mechanism, not just prompt tweaks)
   
4. **Verifier Blindness** — Specialists and Judge get candidates_json + diff only; file contents dropped
   - Fix: give verifiers the same context as the Reviewer before they decide keep/drop
   - Timing: do this before adding new sources

### Severity Calibration (Currently Missing)

- **Enum exists** — ["high", "medium", "low"] is bare with no definition
- **Yet it's load-bearing** — drives ordering, dashboard display, author vs. reviewer split
- **Fix:** Define each level in prompts:
  - High: breaks functionality, security risk, or correctness bug
  - Medium: performance, maintainability, or design issue
  - Low: style note, refactoring suggestion

### Deterministic Validation (v1 Gaps)

- **Security detection** — relies on LLM opinion, not rules (gitleaks/semgrep class scanner needed)
- **Test coverage** — eyeballs whether test files appear in diff, not actual coverage data
- **No validation run** — zero tests, linters, scanners, secret detection, or checkout
- **Fix:** add a scanner (gitleaks/semgrep) for secrets, surface actual test coverage metrics

