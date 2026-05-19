---
id: TX-012
title: Automate Temporal Core descriptor generation
status: To Do
assignee: []
created_date: '2026-05-19 16:36'
labels:
  - backend
  - proto
  - maintenance
dependencies: []
references:
  - priv/proto/temporal_core.binpb
  - ../temporal-sdk-core/crates/common/protos/local
documentation:
  - docs/native.md
  - docs/backend.md
priority: medium
ordinal: 12000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Temporal Core worker protobuf support now depends on priv/proto/temporal_core.binpb, currently generated manually from the sibling ../temporal-sdk-core checkout. Add a maintained regeneration path so descriptor updates are reproducible without keeping ad hoc shell commands in developer memory.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Provide a Mix task or documented repo script that regenerates priv/proto/temporal_core.binpb from the local Temporal Core proto roots.
- [ ] #2 Fail with a clear actionable error when protoc or the expected sibling checkout is missing.
- [ ] #3 Document when the descriptor should be regenerated and how to review the resulting diff.
- [ ] #4 Add a lightweight verification path that catches stale or missing descriptor files without introducing CI/release packaging work.
<!-- AC:END -->
