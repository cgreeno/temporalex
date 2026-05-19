---
id: TX-005
title: Add backend conformance coverage for client operations
status: To Do
assignee: []
created_date: '2026-05-19 15:39'
labels:
  - production-readiness
  - testing
  - backend
dependencies: []
references:
  - test/temporalex/backend_conformance_test.exs
  - lib/temporalex/backend.ex
  - lib/temporalex/backend/test.ex
  - lib/temporalex/backend/temporal_core.ex
documentation:
  - docs/production_readiness_review.md
priority: high
ordinal: 5000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Build conformance tests that compare shared client-operation semantics across the fake/local backend and the Temporal Core backend where both support the operation.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Define a small conformance suite for client operation behavior that can run against multiple backend implementations without duplicating assertions.
- [ ] #2 Cover shared success and error semantics for start/result, signal, query, update or execute_update, cancel, terminate, describe, and new update-handle operations once implemented.
- [ ] #3 Ensure fake backend behavior either conforms for supported operations or clearly reports unsupported operations with stable public errors.
- [ ] #4 Run real Temporal dev-server cases with async false or isolated ports/namespaces so tests are reliable under local and CI execution.
- [ ] #5 Document remaining intentional backend differences in docs/production_readiness_review.md or task notes.
<!-- AC:END -->
