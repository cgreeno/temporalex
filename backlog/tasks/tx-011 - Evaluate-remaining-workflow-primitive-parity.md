---
id: TX-011
title: Evaluate remaining workflow primitive parity
status: To Do
assignee: []
created_date: '2026-05-19 15:40'
labels:
  - production-readiness
  - workflow-core
  - api
  - design
dependencies: []
references:
  - lib/temporalex/workflow/api.ex
  - lib/temporalex/core/executor.ex
  - ../documentation/docs/develop/rust/workflows
documentation:
  - docs/production_readiness_review.md
  - docs/implementation_principles.md
priority: medium
ordinal: 11000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Review and implement or explicitly defer remaining SDK-parity workflow primitives after the foundational wait_condition, child workflow, and external workflow work is underway.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Evaluate cancellation scopes or cancellation handles, local activities, side effects/mutable side effects, memo upsert, workflow logging, interceptors, and workflow headers against docs/implementation_principles.md.
- [ ] #2 For each primitive, record whether it is in scope, deferred, or rejected, with the replay/process/backend rationale.
- [ ] #3 Implement only primitives that can be expressed as executor operations with precise replay behavior and Temporal/Core command mapping.
- [ ] #4 Add focused core tests before backend integration for any accepted primitive.
- [ ] #5 Update production readiness docs and create narrower follow-up backlog tasks for primitives that should not be bundled together.
<!-- AC:END -->
