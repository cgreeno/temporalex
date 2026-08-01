---
id: TX-001
title: Production readiness hardening for Temporal Core beta
status: Done
assignee: []
created_date: '2026-05-07 16:14'
updated_date: '2026-05-07 16:23'
labels:
  - temporal-core
  - beta
  - production-readiness
dependencies: []
priority: high
ordinal: 1000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Track the production-readiness items in scope after the review pass. Explicitly excludes sibling checkout dependency cleanup, safe ETF/pluggable converters, packaging, CI, and release work per current direction.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Temporal Core client bridge supports signal, query, update, cancel, terminate, and describe through Rust NIFs and Elixir client APIs.
- [x] #2 Workflow start/activity options include the practical Temporal policies and metadata needed for beta evaluation, with invalid option values surfaced as errors.
- [x] #3 External integration coverage exercises the new client operations against a real Temporal dev server.
- [x] #4 Review-gate and public-facing docs reflect the implemented beta surface and remaining limits.
- [x] #5 Non-external tests, Rust cargo check, and relevant external integration tests pass.
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented the Temporal Core production-readiness items in scope: native client RPCs for signal/query/update/cancel/terminate/describe, workflow start options, activity retry/cancellation option encoding, invalid duration/retry validation, integration coverage against temporal server start-dev, and docs/review-gate updates. Explicitly left sibling checkout dependencies, safe ETF/pluggable converters, packaging, CI, and release work alone per direction.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Temporal Core beta hardening is complete for this task. Remaining production-readiness gaps are full workflow cancellation propagation, public error struct polish, child workflows, local activities, and Nexus operations.
<!-- SECTION:FINAL_SUMMARY:END -->

## Definition of Done
<!-- DOD:BEGIN -->
- [x] #1 Backlog task status and acceptance criteria are updated.
- [x] #2 jj checkpoint is described before moving to a new change.
<!-- DOD:END -->
