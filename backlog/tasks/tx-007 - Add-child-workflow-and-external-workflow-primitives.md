---
id: TX-007
title: Add child workflow and external workflow primitives
status: To Do
assignee: []
created_date: '2026-05-19 15:39'
labels:
  - production-readiness
  - workflow-core
  - api
  - native
dependencies:
  - TX-006
references:
  - lib/temporalex/workflow/api.ex
  - lib/temporalex/core/executor.ex
  - native/temporalex_nif/src/lib.rs
  - ../temporal-api/temporal/api/command/v1/message.proto
documentation:
  - docs/production_readiness_review.md
  - docs/implementation_principles.md
priority: medium
ordinal: 7000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add production-grade workflow primitives for child workflows and external workflow interactions after the wait_condition foundation is settled.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Expose child workflow start/execute/result/cancel semantics through workflow APIs that map to Temporal commands and preserve deterministic replay.
- [ ] #2 Expose external workflow signal and cancel primitives with explicit target workflow/run identifiers and stable failure behavior.
- [ ] #3 Implement executor commands, replay matching, native command encoding, and real Temporal backend translation for supported primitives.
- [ ] #4 Add core command/replay tests before relying on real backend tests.
- [ ] #5 Add real Temporal dev-server tests for child workflow success/failure/cancellation and external signal/cancel behavior.
<!-- AC:END -->
