---
id: TX-013
title: Evaluate remaining native client conversion ownership
status: To Do
assignee: []
created_date: '2026-05-19 16:36'
labels:
  - backend
  - native
  - client
  - design
dependencies: []
references:
  - native/temporalex_nif/src/lib.rs
  - lib/temporalex/backend/temporal_core/codec.ex
documentation:
  - docs/native.md
  - docs/backend.md
priority: low
ordinal: 13000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
After moving worker-facing Temporal Core protobuf translation to Elixir, the Rust NIF still owns direct client operations and some client option/payload/Search Attribute conversion because it uses temporal-sdk-core client APIs. gRPC/direct service calls are out of scope, but we should explicitly decide whether any common conversion logic should move to Elixir now or stay native until a larger client transport redesign.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Map the client-side conversions still owned by native code, including workflow start options, headers, Search Attributes, retry policy, query/update options, terminate details, and result/failure decoding.
- [ ] #2 Decide which pieces should remain native while the client uses temporal-sdk-core APIs and which, if any, should move to Elixir shared helpers without introducing gRPC scope.
- [ ] #3 If moving logic, keep a single source of truth with the worker codec/payload converter and remove obsolete native helpers instead of adding fallback paths.
- [ ] #4 Add or update focused tests for any conversion ownership change.
<!-- AC:END -->
