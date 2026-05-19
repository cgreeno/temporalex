---
id: TX-006
title: Add deterministic wait_condition workflow primitive
status: To Do
assignee: []
created_date: '2026-05-19 15:39'
labels:
  - production-readiness
  - workflow-core
  - api
  - testing
dependencies: []
references:
  - lib/temporalex/workflow/api.ex
  - lib/temporalex/core/executor.ex
  - lib/temporalex/core/structs.ex
  - docs/programming_model.md
documentation:
  - docs/production_readiness_review.md
  - docs/implementation_principles.md
priority: high
ordinal: 6000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add a general workflow await/wait_condition primitive that lets workflow code block until deterministic workflow state satisfies a predicate, without weakening replay or command ordering.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Design an Elixir API for wait_condition that works from root workflow code and supported handler contexts without backend calls or hidden nondeterministic state.
- [ ] #2 Implement the primitive as an executor operation with precise replay behavior and process lifecycle handling for blocked runner processes.
- [ ] #3 Ensure signals, updates, timer/activity completions, cancellation, and teardown wake or fail waiting processes deterministically.
- [ ] #4 Add core executor tests for satisfaction, blocking, replay, cancellation, and teardown behavior.
- [ ] #5 Add consumer-style Temporalex.Testing examples for common handler patterns that use wait_condition.
<!-- AC:END -->
