# Mewtwo Context Strategy — Compression + Dynamic Context

## Overview

Mewtwo uses two complementary strategies to solve the large-PR problem:

1. **Compression Strategy** — Reduces noise by intelligently shrinking large diffs
2. **Dynamic Context** — Increases signal by fetching semantically relevant context

Together they enable accurate analysis of even massive PRs within token budgets.

---

## Compression Strategy

### Why?

Large PRs (>50KB diffs, >100 files) overwhelm models with noise:
- 400KB raw diff ≈ 200K+ tokens
- Haiku 4.5 has 200K token limit
- Agents get crushed under noise, miss real issues

### How?

**Stage 1: Line-level Compression**
```
Before:
  1: function foo() {
  2:   const x = 1
  3:   const y = 2
  4:   const z = 3        ← changed
  5:   return z
  6: }

After (3-line context window):
  3:   const y = 2
  4:   const z = 3        ← changed
  5:   return z
```

**Stage 2: File Summarization**
```
Before: 500-line file with 1 line changed
  → "// ... 127 unchanged lines ..."
  → actual change
  → "// ... 372 unchanged lines ..."

After: 3-10 line summary
  → "// File Xyz: handles payment processing. Changed: card validation logic."
  → actual change
```

**Stage 3: Pattern Grouping**
```
Before: 10 identical variable renames
  - OLD_VAR → NEW_VAR (in auth.ts)
  - OLD_VAR → NEW_VAR (in middleware.ts)
  - OLD_VAR → NEW_VAR (in handlers.ts)
  ... 7 more times

After: 1 entry
  - "Renamed OLD_VAR → NEW_VAR across 10 files"
```

**Stage 4: Truncation Priority**
If still over budget, truncate in this order:
1. ✅ Changed lines (never truncate)
2. ✅ Test files (high signal)
3. ✅ Config changes (immediate impact)
4. ✅ Comments/docstrings (explain intent)
5. ❌ Unmodified context (lowest value)

### Token Budget

```
Total available: 200K (Haiku limit)
  - 20K: Prompt instruction + agent reasoning
  - 10K: Findings output (must have room for response)
  = 170K for context

Conservative target: 100K context
  - Leaves 70K cushion for agents' internal reasoning
```

---

## Dynamic Context Strategy

### Why?

Raw diff misses crucial context:
- "What code calls this function I just changed?"
- "Are there tests for this module?"
- "What config affects this?"
- "What's the intent per the PR description?"

Agents need **the right context**, not just **more context**.

### How?

**Stage 1: Parse Changed Symbols**

From the diff, extract:
```
Functions: fetch_user(), validate_email()
Classes: PaymentProcessor, AuthMiddleware
Modules: auth.ts, handlers.ts
Imports: import { x } from './utils'
```

**Stage 2: Fetch Related Context (on-demand)**

For each changed symbol:

| Context Type | What to Fetch | Why | Priority |
|---|---|---|---|
| **Callers** | Code that calls modified functions | "Will this break other code?" | High |
| **Tests** | Test files for modified modules | "Is this tested?" | High |
| **Config** | Env configs, feature flags, schema | "What do these changes enable/disable?" | Medium |
| **Docs** | README, CONTRIBUTING, API docs | "What's the intended behavior?" | Medium |
| **Imports** | Dependencies of modified code | "What external libs are affected?" | Low |

**Stage 3: Rank by Relevance**

```
Score = (depth_inverse × relevance_weight) + test_boost

Direct caller (depth=1)      → score 100
Transitive caller (depth=2)  → score 60
Test file (module match)     → score 100
Config file                  → score 70
Comment in changed code      → score 80
Indirect import              → score 20
```

**Stage 4: Budget-Aware Fetching**

```
remaining_tokens = 100K
while (remaining_tokens > 0) {
  next_item = ranked_list.pop()  // highest score first
  next_size = estimate_tokens(next_item)
  
  if (remaining_tokens > next_size) {
    add_to_context(next_item)
    remaining_tokens -= next_size
    record_as_fetched(next_item)
  } else {
    record_as_skipped(next_item)
    break
  }
}

emit_note_to_agent: "Skipped X items due to token limit. Focus on provided context."
```

---

## Integration Flow

```
PR arrives (labeled "initial-review")
  ↓
Fetch raw diff + changed files + commits
  ↓
COMPRESSION PHASE
  ├─ Line-level compression
  ├─ File summarization
  ├─ Pattern grouping
  └─ Token estimate: 85K ✓ (under 100K budget)
  ↓
DYNAMIC CONTEXT PHASE
  ├─ Parse changed symbols
  ├─ Rank related context by relevance
  ├─ Fetch top-scoring items (budget: 15K left)
  └─ Fetched: 2 test files + 1 config file + 3 callers
  ↓
Create prompt with:
  - Compressed diff (85K)
  - Dynamic context (14K)
  - Agent instructions (1K)
  = 100K total ✓
  
  + Note to agent: "Diff compressed 60% (removed 140K unneeded context). 3 callers fetched."
  ↓
Send to agents for analysis
```

---

## Implementation Roadmap

### Phase 1a: Compression Engine
- [ ] `lib/mewtwo/compression.ex` — line-level compression
- [ ] `lib/mewtwo/compression.ex` — file summarization
- [ ] `lib/mewtwo/compression.ex` — pattern grouping
- [ ] Token estimator (count tokens in diff)
- [ ] Tests: compression maintains all changed lines

### Phase 1b: Dynamic Context Fetcher
- [ ] Symbol parser (extract functions, classes, modules from diff)
- [ ] `lib/mewtwo/dynamic_context.ex` — fetcher
- [ ] Code graph queries (find callers — via grep initially, graph later)
- [ ] Test file finder (match test files to modules)
- [ ] Relevance ranker
- [ ] Budget-aware fetcher (stop when token limit hit)
- [ ] Note generator ("skipped X items, focus on provided context")

### Phase 2: Integration
- [ ] Update `lib/mewtwo/pr_context.ex` to use compression + dynamic context
- [ ] Update `lib/mewtwo/workers/review_worker.ex` to track compression metadata
- [ ] Store metadata in DB: {tokens_saved, sections_skipped, items_fetched}

### Phase 3: Monitoring
- [ ] Track compression ratio (target: 50-70%)
- [ ] Track dynamic context effectiveness (which items led to findings?)
- [ ] Dashboard: "PR context profile" (size, compression, dynamic context added)

---

## Trade-offs & Open Questions

### Compression
- **Q:** How aggressive? Remove all context (high compression, high risk)?
- **A:** Keep 3-line context window around changes. Summarize only truly boring sections.
- **Q:** Will agents complain about missing context?
- **A:** Emit note: "Diff compressed from 400K to 85K tokens. If unclear, ask."

### Dynamic Context
- **Q:** How to find callers without a code graph?
- **A:** Start with grep (`grep -r "function_name"` in repo). Upgrade to code graph (Graphify) in Phase 2.
- **Q:** What if context is still insufficient?
- **A:** Agents can request more context (future: re-fetch with specific prompt).

### Combined
- **Q:** When to compress vs. when to reject large PRs?
- **A:** Always compress first. Only reject if compression + dynamic context still exceeds budget.
