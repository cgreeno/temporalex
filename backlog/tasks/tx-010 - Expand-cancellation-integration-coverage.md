---
id: TX-010
title: Expand cancellation integration coverage
status: To Do
assignee: []
created_date: '2026-05-19 15:39'
labels:
  - production-readiness
  - cancellation
  - testing
dependencies: []
references:
  - lib/temporalex/workflow/api.ex
  - lib/temporalex/core/executor.ex
  - test/temporalex/integration
  - test/temporalex/testing_workflow_behavior_test.exs
documentation:
  - docs/production_readiness_review.md
priority: medium
ordinal: 10000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add targeted real-server and consumer-style tests for cancellation paths that remain higher risk after the core cancellation model work.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Add real Temporal dev-server coverage for workflow cancellation while blocked inside an async update handler.
- [ ] #2 Add real Temporal dev-server or consumer-style coverage for cancellation while parallel branches are active.
- [ ] #3 Assert cleanup behavior through non_cancellable sections where relevant, including access to workflow state so far.
- [ ] #4 Keep real-server tests async false or otherwise isolate namespaces/ports/workflow ids to avoid flakiness.
- [ ] #5 Document any scenarios that remain untestable because Temporal Core does not expose cancellation details or server behavior is nondeterministic.
<!-- AC:END -->
