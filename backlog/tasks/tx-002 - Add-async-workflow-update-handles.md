---
id: TX-002
title: Add async workflow update handles
status: To Do
assignee: []
created_date: '2026-05-19 15:37'
labels:
  - production-readiness
  - client
  - updates
  - native
dependencies: []
references:
  - lib/temporalex/client.ex
  - lib/temporalex/backend.ex
  - lib/temporalex/backend/temporal_core.ex
  - native/temporalex_nif/src/lib.rs
  - ../temporal-sdk-core/crates/client/src/workflow_handle.rs
documentation:
  - docs/production_readiness_review.md
priority: high
ordinal: 2000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement Temporal-style async update client semantics: execute_update waits for completion, start_update returns after acceptance, get_update_result polls by update id, and update handles are Elixir value structs that can be reattached by workflow/update identifiers.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Expose Client.execute_update/4,5, Client.start_update/4,5, Client.get_update_result/2, and a Client.UpdateHandle struct with client, workflow_id, run_id, update_id, update_name, and workflow_type metadata.
- [ ] #2 Keep public update handles as Elixir values, not opaque native resources; provide a way to construct or reattach a handle from client, workflow_id, update_id, and optional run_id.
- [ ] #3 Extend the backend contract and Temporal Core backend with start_update and get_update_result operations while preserving client owner monitoring and ClientUnavailableError behavior.
- [ ] #4 Implement native start and poll support against Temporal update RPCs or an equivalent Core helper, including lifecycle wait-stage handling and polling until completion or timeout.
- [ ] #5 Normalize update rejection/failure errors into public Temporalex.UpdateFailedError values with update_name and update_id context.
- [ ] #6 Add real Temporal dev-server tests for accepted-before-completed async updates, later result retrieval, rejected updates, idempotent update_id behavior, and reattached handle polling.
<!-- AC:END -->
