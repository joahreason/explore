# Development Workflow

## Standard Claude Session

Use this loop for most development tasks:

```text
Understand → Plan → Implement → Verify → Review → Record
```

### 1. Understand

Inspect the smallest relevant portion of the repository.

Find:
- Existing implementation
- Related abstractions
- Tests
- Configuration
- Documentation

### 2. Plan

For meaningful changes, establish:
- Desired behavior
- Integration point
- Files to change
- Verification strategy

Keep the plan proportional to the task.

### 3. Implement

Make a focused change.

Avoid unrelated refactors.

### 4. Verify

Use progressively broader checks:

```text
targeted test
    ↓
related tests
    ↓
build / lint / typecheck
    ↓
integration or runtime verification
```

Do not perform expensive checks unnecessarily when a narrow check provides
sufficient confidence.

### 5. Review

Inspect the diff and ask:

- Did I change anything unrelated?
- Did I introduce unnecessary complexity?
- Did I preserve existing behavior?
- Did I actually satisfy the request?
- Are there edge cases?
- Is documentation needed?

### 6. Record

Update project state when the change affects future work.

---

## Fresh Context Strategy

A new Claude session should be able to recover using:

1. `CLAUDE.md`
2. `PROJECT_STATE.md`
3. `TODO.md`
4. Relevant `docs/`
5. Recent Git history
6. Relevant source files

The repository should be the source of truth, not a previous conversation.

---

## Task Sizing

Prefer tasks that produce one coherent milestone.

Good:

- Implement tree placement.
- Add deterministic resource sampling.
- Add biome density modifiers.
- Add debug visualization.
- Profile world generation.

Too broad:

- Finish procedural generation.
- Build the entire survival system.
- Make the game feel better.

Break broad goals into concrete milestones.

---

## Planning vs Implementation

Use planning when:
- Multiple systems interact.
- Architecture is uncertain.
- The change affects many files.
- The feature has meaningful tradeoffs.

Skip elaborate planning when:
- The change is obvious.
- The implementation is local.
- Existing patterns clearly dictate the solution.

Do not spend more context planning a simple change than implementing it.

---

## Debugging

When debugging:

1. Reproduce the issue.
2. Establish the expected behavior.
3. Inspect the relevant execution path.
4. Form a hypothesis.
5. Add targeted instrumentation if useful.
6. Test the hypothesis.
7. Fix the root cause.
8. Add a regression test when practical.

Do not make random changes until the symptom disappears.

For procedural systems, prefer debug visualizations and measurable diagnostics
over subjective tuning alone.

---

## Procedural / Simulation Projects

For world generation, simulation, AI, physics, or other complex systems:

Prefer exposing intermediate values such as:

- Input parameters
- Noise values
- Classification results
- Probabilities
- Selected categories
- Rejection reasons
- Final placement

Debug tooling often provides more long-term value than repeatedly tuning values
blindly.

Preserve determinism when it is a project requirement.

---

## Performance Work

Do not optimize based solely on intuition.

Use this sequence:

```text
Measure → Identify bottleneck → Change → Measure again
```

Record meaningful performance findings when they affect architecture.

Avoid premature optimization of code that has not been demonstrated to matter.

---

## Refactoring

Refactor when it improves a concrete property such as:
- Correctness
- Testability
- Performance
- Maintainability
- Required feature development

Avoid refactoring simply because code could look cleaner.

When refactoring, preserve behavior unless behavior change is explicitly part
of the task.
