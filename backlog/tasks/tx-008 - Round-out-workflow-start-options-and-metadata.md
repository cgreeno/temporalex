---
id: TX-008
title: Round out workflow start options and metadata
status: To Do
assignee: []
created_date: '2026-05-19 15:39'
labels:
  - production-readiness
  - client
  - native
  - options
dependencies: []
references:
  - lib/temporalex/client.ex
  - lib/temporalex/backend/temporal_core.ex
  - native/temporalex_nif/src/lib.rs
  - ../temporal-api/temporal/api/workflowservice/v1/request_response.proto
documentation:
  - docs/production_readiness_review.md
priority: medium
ordinal: 8000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Complete the remaining workflow start option surface that production users expect, while keeping option names Elixir-friendly and Temporal semantics intact.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Add supported workflow start options for request id, memo, start delay, priority, links, callbacks, versioning override, on-conflict behavior, and eager execution controls where Temporal Core/server support them.
- [ ] #2 Validate option combinations locally when Temporal semantics are clear, and surface invalid options as public client errors.
- [ ] #3 Reuse typed Search Attribute and payload encoders consistently for memo, headers, links/callback payloads, and future continue-as-new/child workflow option paths.
- [ ] #4 Add native codec tests for option encoding and real Temporal dev-server smoke tests for the options that can be observed reliably.
- [ ] #5 Document unsupported or deferred Temporal fields with reasons if Core/server support is missing or semantically unclear.
<!-- AC:END -->
