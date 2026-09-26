# Development Workflow

How to work on this repository: the session loop, then setup, tests, renders,
deploys and the gotchas found so far. `CLAUDE.md` has the rules; this file has
the how-to.

## Session loop

```text
Understand → Plan → Implement → Verify → Review → Record
```

1. **Understand.** Inspect the smallest relevant part of the repository: the
   existing implementation, related abstractions, tests, configuration, docs.
2. **Plan.** For meaningful changes, settle the desired behavior, the
   integration point, the files to change and how to verify. Keep the plan
   proportional to the task.
3. **Implement.** A focused change; no unrelated refactors.
4. **Verify.** Widen step by step, and don't run expensive checks when a
   narrow one gives enough confidence:

   ```text
   targeted test → related tests → build / lint / typecheck → integration or runtime check
   ```

5. **Review.** Read the diff: anything unrelated? unnecessary complexity?
   existing behavior kept? request actually met? edge cases? docs needed?
6. **Record.** Update the project files when the change affects future work
   (see "Where things are recorded" below).

### Fresh context

A new session recovers from the repository, not from a previous
conversation:

1. `CLAUDE.md`
2. `PROJECT_STATE.md` (snapshot, under 10 KB)
3. `TODO.md` (the only backlog)
4. The relevant `docs/`: `architecture.md`, `decisions.md`, this file,
   `tuning-log.md`, `resource-generation-plan.md`
5. Recent Git history (`CHANGELOG_DEV.md` for the longer story)
6. The relevant source files

### Task sizing

Prefer tasks that give one coherent milestone ("add deterministic resource
sampling", "add a debug visualization", "profile world generation"). "Finish
procedural generation" or "make the game feel better" is too broad: break it
into concrete milestones.

### Planning vs. implementation

Plan when several systems interact, the architecture is uncertain, the
change touches many files or has real trade-offs. Skip elaborate planning
when the change is obvious, local, or dictated by existing patterns. Don't
spend more context planning a simple change than implementing it.

### Debugging

1. Reproduce the issue.
2. Establish the expected behavior.
3. Inspect the execution path.
4. Form a hypothesis.
5. Add targeted instrumentation if useful.
6. Test the hypothesis.
7. Fix the root cause.
8. Add a regression test when practical.

Don't make random changes until the symptom disappears.

### Procedural and simulation work

Prefer debug visualizations and measurable diagnostics over subjective
tuning. Expose intermediate values: input parameters, noise values,
classification results, probabilities, selected categories, rejection
reasons, final placement. Debug tooling usually pays off more than tuning
blind. Keep generation deterministic.

### Performance work

```text
Measure → Identify bottleneck → Change → Measure again
```

Don't optimize on intuition, or code that hasn't been shown to matter.
Record findings that affect architecture (`docs/tuning-log.md` for the
numbers).

### Refactoring

Refactor when it improves something concrete: correctness, testability,
performance, maintainability, or a feature that needs it. Not because code
could look cleaner. Keep behavior unless changing it is part of the task.
