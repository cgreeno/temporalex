---
id: TX-009
title: Complete Temporal failure decoder coverage
status: To Do
assignee: []
created_date: '2026-05-19 15:39'
labels:
  - production-readiness
  - failures
  - native
  - testing
dependencies: []
references:
  - lib/temporalex/failure.ex
  - native/temporalex_nif/src/lib.rs
  - ../temporal-api/temporal/api/failure/v1/message.proto
documentation:
  - docs/production_readiness_review.md
  - docs/failure_model_proposal.md
priority: medium
ordinal: 9000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Map and test remaining Temporal failure proto variants so clients receive stable Temporalex.Failure structs instead of avoidable UnknownError values.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Inventory Temporal failure proto variants still decoded as Temporalex.Failure.UnknownError and decide the public struct shape for each supported variant.
- [ ] #2 Implement native inbound and outbound failure mapping for supported variants without flattening causes or details.
- [ ] #3 Add unit/native codec tests for each mapped variant, including recursive cause preservation.
- [ ] #4 Add real Temporal dev-server coverage where a variant can be produced reliably without brittle server internals.
- [ ] #5 Document any intentionally unsupported variants and keep them as UnknownError with enough raw context for debugging.
<!-- AC:END -->
