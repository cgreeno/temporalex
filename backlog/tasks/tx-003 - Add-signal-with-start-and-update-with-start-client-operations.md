---
id: TX-003
title: Add signal-with-start and update-with-start client operations
status: To Do
assignee: []
created_date: '2026-05-19 15:38'
labels:
  - production-readiness
  - client
  - updates
  - signals
  - native
dependencies: []
references:
  - lib/temporalex/client.ex
  - lib/temporalex/backend.ex
  - native/temporalex_nif/src/lib.rs
  - ../temporal-api/temporal/api/workflowservice/v1/request_response.proto
documentation:
  - docs/production_readiness_review.md
priority: high
ordinal: 3000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add Temporal client operations that combine workflow start with a signal or update, including the ExecuteMultiOperation update-with-start path where supported by Temporal.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Expose Elixir-friendly signal_with_start and update_with_start APIs using explicit client ownership and no internal worker-created clients.
- [ ] #2 Map workflow start options consistently with existing start_workflow, including workflow id policies, task queue, headers, memo, search attributes, retry policy, and timeouts where supported.
- [ ] #3 Implement native support for SignalWithStartWorkflowExecutionRequest and ExecuteMultiOperationRequest update-with-start semantics, or document any Temporal Core impedance mismatch before proceeding.
- [ ] #4 Return normal workflow handles and update handles/results with stable public error structs for already-started, not-found, update failure, and transport errors.
- [ ] #5 Add real Temporal dev-server tests for new execution, existing execution, idempotent request/update ids, and rejection/failure paths.
<!-- AC:END -->
