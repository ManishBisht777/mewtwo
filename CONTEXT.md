# Code Review Agent System — Domain Language

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

A coordinator agent that receives findings from all specialized agents and produces the two final outputs. Categorizes findings as author-actionable vs. reviewer-level risk, ranks by severity/confidence.

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

Numeric or categorical confidence (e.g., "high", "medium", "low") attached to each agent finding. Used by judge to rank findings and flag uncertain analysis in reviewer output.

## Relationships

- One PR → one review (at a time; stale reviews are replaced, not accumulated)
- One review → multiple agents (5+ core agents, expanding to 10+)
- One review → two outputs (author-facing and reviewer-facing)
- All agents → one judge agent → two outputs
- Each agent → independent feedback loop and iterative improvement
