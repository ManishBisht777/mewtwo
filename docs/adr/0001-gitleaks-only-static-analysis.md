# ADR-0001: Static Analysis Strategy for v2 — Gitleaks + LLM, Skip CI Duplication

**Date:** 2026-09-02  
**Status:** Accepted  
**Deciders:** Manish

## Context

Mewtwo's code review system will use both **deterministic static analysis** and **LLM agents** to find issues in PRs. The question: which static analysis tools to include?

### Two Approaches

**Option 1: Full Static Tooling (Semgrep, Linters, SAST)**

- Pros: Comprehensive pattern detection, catch known vulnerabilities
- Cons: Duplicate CI/CD pipelines (most repos already run these), slower reviews, larger token budget

**Option 2: Gitleaks Only + LLM Focus**

- Pros: Unique value (secrets detection often missing in CI), no CI duplication, faster, simpler
- Cons: Limited deterministic coverage, rely on LLM for pattern detection

## Decision

**Option 2: Gitleaks-only static analysis in v2. Defer Semgrep and language-specific linters to v3+.**

### Rationale

1. **CI Duplication** — Most repositories already run Semgrep, ESLint, Pylint, etc. in their CI/CD pipelines. Reproducing those checks in Mewtwo wastes compute and adds latency.

2. **Secrets Detection Gap** — Gitleaks is often _not_ run in CI (requires separate setup). Secret detection is deterministic, high-value, and complements LLM analysis well.

3. **Token Budget** — v2 targets 100K tokens per review. Embedding multiple tool findings bloats context. Gitleaks findings are sparse (~1-2K tokens), leaving room for rich LLM analysis.

4. **LLM is Unique** — The value of Mewtwo is _not_ pattern matching (CI tools do that). It's semantic understanding: "Is this null-safe?" "Does this break backwards compatibility?" "Is this the right design?" LLM analysis is the differentiator.

5. **Speed** — Gitleaks runs in <1s. Semgrep can take 10-30s on large repos. v2 prioritizes fast feedback (target: <10s review time).

### Revision Path

v3+ will add:

- Semgrep (custom rules per codebase)
- Language-specific linters (as opt-in per repo config)
- Build system checks (did the build pass?)

These are deferred, not eliminated. If a customer needs Semgrep integration, it's a straightforward addition.

## Architecture Impact

```
V2 Flow:
  Fetch diff
    ↓
  Compress (50-70% reduction)
    ↓
  Fetch light dynamic context
    ↓
  [PARALLEL]
    ├─ Gitleaks (secrets only, <1s)
    └─ Agents (LLM analysis, semantic understanding)
    ↓
  Judge (scores: LLM + Gitleaks agreement → high confidence)
    ↓
  Post to GitHub
```

**Tool Agreement Scoring:**

- LLM + Gitleaks find same issue (file+line+category) → **high confidence**
- LLM finds issue (no Gitleaks match) → **medium confidence**
- Gitleaks finds issue (agents didn't catch) → **medium confidence**

## Risks

1. **LLM Hallucinations** — Without Semgrep as guardrail, agents might flag false positives. Mitigated by: Judge's confidence scoring, reviewer-level risk summary (not auto-approved).

2. **Pattern Misses** — Classic bugs (SQL injection, hardcoded creds, null deref) might be missed by LLM. Mitigated by: Gitleaks catches secrets, agents catch semantic issues.

3. **Cost Creep** — If customers complain about missed patterns, we'll add Semgrep anyway. Acceptable: v3 pivot is low-cost.

## Success Criteria

- ✅ v2 reviews complete in <10 seconds (Gitleaks won't block)
- ✅ Token budget stays ≤100K per review
- ✅ Secret detection improves (Gitleaks catches what CI misses)
- ✅ LLM findings rate improves (agents not crowded out by tool noise)

## Alternatives Considered

- **A1: Full Semgrep + Gitleaks** — Rejected: CI duplication, slower, larger token budget
- **A2: No static tools, LLM-only** — Rejected: Lose deterministic confidence signal, secrets slip through
- **A3: Tool-first, LLM-second** — Rejected: Wrong priority, tools are easier than semantic analysis

---

**Revision History**

- v1 (2026-09-02): Initial decision, locked in with team grilling session
