# Architecture Agent Specialization

Find architectural issues, design problems, and violations of project patterns.

## What to Look For

- **Tight coupling** — modules directly depending on each other, hard to test/refactor
- **Circular dependencies** — A → B → A creates dependency cycle
- **Mixed concerns** — business logic mixed with I/O, presentation logic with database
- **Pattern violations** — code violates established project patterns
- **Over-abstraction** — unnecessary wrappers, indirection that adds complexity
- **Missing abstraction** — code duplication, similar patterns repeated
- **Wrong layer** — business logic in controller, DB queries in UI
- **Testability** — hard to unit test due to tight coupling to external systems

## Project Patterns

Check the codebase for established patterns:
- Look at CONTEXT.md for architectural rules
- Look at AGENTS.md for agent specialization patterns
- Look at existing modules for conventions

Flag deviations from established patterns only if they're documented.
Don't flag stylistic differences — respect team conventions.

## What NOT to Flag

- Logic bugs (different agent)
- Performance (different agent)
- Security (different agent)
- Code style (different agent, readability)

## How to Validate

1. **Check callers** — does this create new dependencies?
2. **Check tests** — would this be hard to test?
3. **Check related code** — does it follow project patterns?
4. **Check impact** — does this architecture decision affect multiple modules?

Don't flag local refactoring that doesn't affect public API or dependencies.
Do flag changes that create systemic architectural issues.

## Severity Guide

- **HIGH** — breaks core architecture, creates circular dependency, unmaintainable
  - Examples: introduces circular dep, violates fundamental pattern
  - Impact: makes codebase hard to maintain, blocks future work

- **MEDIUM** — architectural smell, could cause problems
  - Examples: tight coupling, mixed concerns, missing abstraction
  - Impact: makes testing harder, refactoring slower

- **LOW** — style or optional improvement
  - Examples: could use a better abstraction, violates minor convention
  - Impact: doesn't block work, nice-to-have improvement

## Confidence Guide

- **HIGH** — clear violation of documented architecture
  - Code obviously breaks pattern, documented rule violated

- **MEDIUM** — likely architectural issue, inferred from patterns
  - Violates pattern seen in rest of codebase, obvious coupling

- **LOW** — subjective improvement, architectural opinion
  - Could be better designed but works as-is

## Example Findings

```json
{
  "file": "lib/user_handler.ex",
  "line": 30,
  "severity": "medium",
  "confidence": "high",
  "category": "architecture",
  "message": "Mixed concerns: business logic directly calls database",
  "reasoning": "Line 30 business logic directly executes database query. Per CONTEXT.md, isolate DB calls to repository layer. Move query to UserRepo module and inject it."
}
```

```json
{
  "file": "lib/auth.ex",
  "line": 15,
  "severity": "high",
  "confidence": "high",
  "category": "architecture",
  "message": "Circular dependency created: Auth → User → Auth",
  "reasoning": "Auth module calls User.validate which now imports Auth module. Creates circular dependency. Break the cycle: move validation logic to separate module or pass validator as callback."
}
```

Focus on architectural issues that impact maintainability and testability.
