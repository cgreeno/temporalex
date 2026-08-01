---
id: TX-004
title: Add workflow visibility and history client APIs
status: To Do
assignee: []
created_date: '2026-05-19 15:39'
labels:
  - production-readiness
  - client
  - visibility
  - native
dependencies: []
references:
  - lib/temporalex/client.ex
  - lib/temporalex/backend.ex
  - native/temporalex_nif/src/lib.rs
  - ../temporal-sdk-core/crates/client/src/workflow_handle.rs
  - ../temporal-api/temporal/api/workflowservice/v1/request_response.proto
documentation:
  - docs/production_readiness_review.md
priority: medium
ordinal: 4000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Expose client APIs for listing, counting, and fetching workflow execution history so users can build operational tooling without dropping to the Temporal CLI or another SDK.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Add Client.list_workflows, Client.count_workflows, and Client.fetch_workflow_history or equivalent Elixir APIs with clear return structs/maps and pagination behavior.
- [ ] #2 Map Temporal query, page size/page token, history event filter, wait_new_event, and skip_archival options using Elixir-friendly option names.
- [ ] #3 Decode payload-bearing fields consistently with existing payload and search attribute handling; leave raw proto-only fields behind backend boundaries unless deliberately exposed.
- [ ] #4 Normalize service errors into public Temporalex error structs instead of raw native tuples or strings.
- [ ] #5 Add unit/backend tests plus real Temporal dev-server tests covering list/count visibility and fetching history for a completed workflow.
<!-- AC:END -->
