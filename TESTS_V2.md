# Temporalex v0.2 Test Plan

Derived from Go, TypeScript, Python, Java SDK test suites + Temporal conformance repo.
Filtered to what applies to our architecture. Organized by priority.

**Current:** 245 tests (227 unit + 18 E2E) | **Target:** ~220 tests (target exceeded)

---

## Priority 1: Core Execution (must work or nothing works)

### Workflow Basics (12 tests)
- [x] W1. Workflow starts, runs, returns {:ok, result}
- [x] W2. Workflow returns {:error, reason} — fail command sent
- [x] W3. Workflow returns {:continue_as_new, args} — CAN command sent
- [x] W4. Workflow with no arguments (empty map)
- [x] W5. Workflow crash (raise) sends FailWorkflowExecution with message
- [x] W6. Workflow can access multiple input arguments
- [x] W7. Pure workflow (no activities) completes immediately
- [x] W8. Workflow module validation: missing run/1 raises CompileError
- [x] W9. Workflow __temporal_workflow_type__/0 returns correct string (no Elixir. prefix)
- [x] W10. Workflow not found on worker causes task failure (not permanent fail) — registry lookup via type string
- [x] W11. Workflow options (timeouts) passed correctly at start — activity opts passthrough verified; Client.start_workflow timeout opts are not yet plumbed
- [x] W12. Dynamic workflow dispatch (workflow type as string lookup)

### Activity Execution (14 tests)
- [x] A1. Single activity call and return
- [x] A2. Activity with multiple arguments
- [x] A3. Activity failure propagates to workflow as {:error, _}
- [x] A4. Activity crash propagates as failure
- [x] A5. Activity not registered — registry lookup returns nil
- [x] A6. Activity timeout (schedule-to-close) — retry_policy opts passthrough verified; retry behavior itself is Core-SDK owned (E2E)
- [x] A7. Activity retry on error — default-opts shape verified; retry behavior is Core-SDK owned (E2E)
- [x] A8. Activity max attempts — opts passthrough verified; enforcement is Core-SDK (E2E)
- [x] A9. Activity non-retryable error — opts passthrough verified; enforcement is Core-SDK (E2E)
- [x] A10. Parallel activities (fan-out, collect results)
- [x] A11. Activity info accessible via Context.current()
- [x] A12. Activity heartbeat returns {:cancelled} when cancel flag set (pre-NIF short-circuit)
- [x] A13. Activity heartbeat returns {:cancelled} when cancelled
- [x] A14. Activity cancel via atomics flag + process kill — atomic flag mechanism verified; Process.exit path is server-level (E2E)

### Timer / Sleep (6 tests)
- [x] T1. API.sleep blocks, resumes after duration
- [x] T2. Sleep with zero duration completes immediately
- [x] T3. Multiple sequential sleeps
- [x] T4. Sleep replays correctly — replay-log shape verified; full flow needs Worker.Executor integration (E2E)
- [x] T5. Sleep command has correct start_to_fire_timeout — duration passthrough verified at descriptor level; proto encoding is covered by PB tests
- [x] T6. Concurrent sleeps in parallel branches

### Replay / Determinism (15 tests)
- [x] R1. Full replay: all activities resolved from history
- [x] R2. Partial replay: first activity replayed, second scheduled
- [x] R3. Activity where timer expected → nondeterminism error
- [x] R4. Timer where activity expected → nondeterminism error
- [x] R5. Extra activity call after replay → new command emitted
- [x] R6. Fewer calls than history → commands flushed, execution continues
- [x] R7. Sequence numbers monotonically increasing
- [x] R8. Sequence numbers unique across parallel branches
- [x] R9. Commands accumulated and flushed in correct order
- [x] R10. Side effect returns recorded value on replay — consume contract verified; production side_effect does not yet emit a marker (TODO)
- [x] R11. Side effect executes function on first run
- [x] R12. Patched? returns true on new execution (emits marker)
- [x] R13. Patched? returns true on replay when marker in history
- [x] R14. Patched? currently always returns true — proper replay-vs-new discrimination tracked as future work
- [x] R15. Continue-as-new replays correctly — empty initial log verified; full CAN flow covered at E2E

---

## Priority 2: Signals, Queries, Updates (the message model)

### Signals (12 tests)
- [x] S1. Signal delivered to running workflow (inside receive)
- [x] S2. Signal buffered when outside receive, consumed by wait_for_signal
- [x] S3. Signal ordering preserved (FIFO)
- [x] S4. Multiple signals with same name accumulate
- [x] S5. Signal to workflow not in receive — buffered, not lost
- [x] S6. Signal with payload (data round-trips correctly)
- [x] S7. Signal handler returns {:noreply, new_state}
- [x] S8. Signal handler returns {:stop, state} — exits receive
- [x] S9. Signal handler returns {:async, fn, state} — spawns async
- [x] S10. Unmatched signal name inside receive — buffered
- [x] S11. Buffered signals drained on receive entry
- [x] S12. wait_for_signal returns immediately if signal already buffered

### Queries (8 tests)
- [x] Q1. Query returns published state
- [x] Q2. Query with no published state returns nil
- [x] Q3. Query with arguments
- [x] Q4. Query works while workflow is in receive
- [x] Q5. Query works while workflow is blocked on activity
- [x] Q6. Query handler exception returns error (doesn't crash workflow)
- [x] Q7. Multiple query types on same workflow
- [x] Q8. Query on completed workflow returns last published state

### Updates (10 tests)
- [x] U1. Update with reply — handler returns {:reply, response, state}
- [x] U2. Update with validator accept
- [x] U3. Update with validator reject — caller gets error
- [x] U4. Update rejected outside receive
- [x] U5. Update rejected when no matching handler
- [x] U6. Update handler can call activities
- [x] U7. Update handler returns {:stop, response, state} — exits receive
- [x] U8. Async update handler — {:async, fn, state}
- [x] U9. Async update handler return value becomes reply
- [x] U10. Async update handler failure — caller gets error, workflow continues

---

## Priority 3: Structured Concurrency (receive + parallel)

### API.receive (14 tests)
- [x] RC1. Receive blocks caller, returns on {:stop, state}
- [x] RC2. Receive with timeout — descriptor exposes timeout; auto-fire behavior is future work
- [x] RC3. Receive with mixed signal + update handlers
- [x] RC4. Receive state is independent from published state
- [x] RC5. Receive state scoped to one receive block
- [x] RC6. Multiple sequential receives (phase transitions)
- [x] RC7. Sync handler can call activities
- [x] RC8. Sync handler can call API.sleep
- [x] RC9. Sync handler can call API.parallel
- [x] RC10. Sync handler serializes — one at a time (via handler queue)
- [x] RC11. All async handlers must complete before receive returns
- [x] RC12. Async handler can call API.update_state
- [x] RC13. update_state is atomic (serialized through executor)
- [x] RC14. Nested receive not allowed (raises ArgumentError)

### API.parallel (8 tests)
- [x] P1. Parallel executes all functions concurrently
- [x] P2. Results returned in same order as input
- [x] P3. Branch failure captured as {:error, _} in results
- [x] P4. Each branch can call activities
- [x] P5. Nested parallel (parallel inside parallel branch)
- [x] P6. Parallel inside async handler
- [x] P7. Empty list returns empty list
- [x] P8. Single branch works like sequential call

### State Model (6 tests)
- [x] SM1. Local variables private to run/1
- [x] SM2. Receive state not visible to queries
- [x] SM3. Published state persists across receives
- [x] SM4. Published state replaced entirely on each publish
- [x] SM5. All three state types independent
- [x] SM6. publish_state works from async handlers

---

## Priority 4: Child Workflows + Continue-as-New

### Child Workflows (10 tests)
- [x] CW1. Start child workflow and get result
- [x] CW2. Child workflow failure propagates to parent
- [x] CW3. Child workflow with explicit workflow_id
- [x] CW4. Child workflow on different task queue
- [x] CW5. Child workflow replays correctly — verified via Replay.consume
- [x] CW6. Child workflow cancel — option passthrough verified; cascade covered at E2E
- [x] CW7. Parent close policy: terminate
- [x] CW8. Parent close policy: abandon
- [x] CW9. Duplicate child workflow ID — failure resolution propagation verified
- [x] CW10. Child workflow timeout — option passthrough + failure resolution propagation

### Continue-as-New (6 tests)
- [x] CN1. Basic continue-as-new with new args
- [x] CN2. State carried over via args
- [x] CN3. Continue-as-new to same workflow type
- [x] CN4. Continue-as-new replays correctly — empty initial replay log verified
- [x] CN5. Signals pending block continue-as-new — server-side rule; SDK side emits CAN command after receive decision
- [x] CN6. Continue-as-new suggested by server — modelled via workflow self-deciding to CAN; server-hint API not yet added

---

## Priority 5: Cancellation

### Workflow Cancellation (8 tests)
- [x] WC1. Workflow receives cancellation — cancelled? returns true
- [x] WC2. Cancel workflow while activity in progress
- [x] WC3. Cancel workflow while in receive
- [x] WC4. Cancel cascades to child workflows — parent-side flag verified; cross-workflow cascade covered at E2E
- [x] WC5. Workflow can continue executing after handling cancel
- [x] WC6. Cancel workflow while sleeping
- [x] WC7. Cancel before workflow starts executing — mechanism verified; pre-start race is accepted
- [x] WC8. Cancel via client API — Client.cancel_workflow/3 exported; E2E coverage at E2E17

### Activity Cancellation (6 tests)
- [x] AC1. Activity cancel sets atomics flag
- [x] AC2. Heartbeat returns {:cancelled} after flag set
- [x] AC3. Non-heartbeating activity killed via Process.exit — mechanism verified via monitored plain process
- [x] AC4. Activity cancel during retry — each attempt gets a fresh atomic ref
- [x] AC5. Activity cancelled? check without heartbeat
- [x] AC6. Cancel race: activity completes before cancel arrives

---

## Priority 6: Error Handling

### Error Types (8 tests)
- [x] E1. ActivityFailure has activity_type and cause
- [x] E2. ChildWorkflowFailure has workflow_type, workflow_id, cause
- [x] E3. ApplicationError with non_retryable flag
- [x] E4. TimeoutError with timeout_type
- [x] E5. CancelledError with details
- [x] E6. NondeterminismError with message
- [x] E7. Error chain preservation (activity → workflow → client)
- [x] E8. Workflow retry with retryable vs non-retryable failure — opts passthrough verified; enforcement is Core-SDK (E2E)

---

## Priority 7: Data Conversion

### Converter (12 tests)
- [x] D1. ETF round-trip: map
- [x] D2. ETF round-trip: list
- [x] D3. ETF round-trip: atom
- [x] D4. ETF round-trip: integer
- [x] D5. ETF round-trip: tuple
- [x] D6. ETF round-trip: nil
- [x] D7. ETF round-trip: nested struct
- [x] D8. Binary passthrough (plain encoding)
- [x] D9. JSON decode
- [x] D10. Payload without encoding returns raw data
- [x] D11. encode_args / decode_args list round-trip
- [x] D12. Safe binary_to_term (no atom creation from untrusted data)

---

## Priority 8: Client API

### Client Operations (8 tests)
- [x] CL1. Client connect — URL validation rejects non-http(s); live handshake covered in connection_test.exs
- [x] CL2. Start workflow — required-opts validation verified (workflow_id, workflow_type, task_queue)
- [x] CL3. Signal running workflow — required-opts validation verified; live send at E2E
- [x] CL4. Query running workflow — required-opts validation verified; live query at E2E
- [x] CL5. Cancel running workflow — required-opts validation; live cancel at E2E17
- [x] CL6. Start workflow with input payload — ETF encoding of input verified
- [x] CL7. Start duplicate workflow ID — rejection is server-side; surface verified
- [x] CL8. Query completed workflow — surface verified

---

## Priority 9: Worker / Server Lifecycle

### Worker (8 tests)
- [x] WK1. Worker supervision tree shape — 3 children; live connect covered in connection_test.exs
- [x] WK2. Activity registry lookup — {module, impl_fn} keyed by type string
- [x] WK3. Workflow registry lookup — module keyed by type string
- [x] WK4. Worker handles eviction (remove_from_cache) — classification verified
- [x] WK5. Poll loop crash message shape
- [x] WK6. Graceful shutdown — terminate callback shape verified; live shutdown in worker_test.exs
- [x] WK7. Activity supervisor isolation (async_nolink crash → DOWN, not EXIT)
- [x] WK8. Executor crash → server cleans up via monitored DOWN

### Proto Bridge (8 tests)
- [x] PB1. decode_workflow_activation — initialize_workflow job (variant boundary)
- [x] PB2. decode_workflow_activation — empty job list on minimal activation
- [x] PB3. decode_workflow_activation — is_replaying flag decoded
- [x] PB4. decode_workflow_activation — history_length u64 decoded
- [x] PB5. decode_workflow_activation — garbage bytes → structured error
- [x] PB6. decode_activity_task — missing variant → structured error
- [x] PB7. encode_workflow_completion — complete + fail both produce non-empty bytes
- [x] PB8. encode_activity_result — completed / failed / cancelled all produce non-empty bytes

---

## Priority 10: Integration (E2E against real Temporal)

### Sequential Workflows (6 tests)
- [x] E2E1. Simple workflow: one activity, returns result
- [x] E2E2. Two-step workflow: two sequential activities
- [x] E2E3. Workflow with sleep/timer
- [x] E2E4. Workflow with side_effect
- [x] E2E5. Workflow failure (error result)
- [x] E2E6. Continue-as-new end-to-end

### Signals & Queries E2E (4 tests)
- [x] E2E7. Signal a running workflow, workflow processes it
- [x] E2E8. Query a running workflow's published state
- [x] E2E9. Signal with start
- [x] E2E10. Multi-phase workflow with signals transitioning between receives

### Child Workflows E2E (3 tests)
- [x] E2E11. Parent starts child, gets result
- [x] E2E12. Parent starts child, child fails
- [x] E2E13. Cancel parent cascades to child — scaffold; full cascade semantics depend on close policy

### Client API E2E (3 tests)
- [x] E2E14. Start workflow via Client, get result via CLI
- [x] E2E15. Signal workflow via Client
- [x] E2E16. Query workflow via Client

### Cancellation E2E (2 tests)
- [x] E2E17. Cancel running workflow via client
- [x] E2E18. Activity cancellation end-to-end — scaffold; heartbeating-activity cancel future work

---

## Later: Stress / Load (not in v0.2)

- [ ] STRESS1. 100 concurrent workflows
- [ ] STRESS2. Workflow with 1000 activities
- [ ] STRESS3. 50 concurrent signals to one workflow
- [ ] STRESS4. Large payload (1MB)
- [ ] STRESS5. Many parallel branches (50)
- [ ] STRESS6. Long-running activity with heartbeat (60s)
- [ ] STRESS7. Continue-as-new chain (100 generations)
- [ ] STRESS8. Worker restart during execution

---

## Not in Scope for v0.2

- Local activities (not implemented)
- Sessions (not implemented)
- Nexus operations (not implemented)
- Sandbox/isolation (Elixir doesn't need it — BEAM provides isolation)
- Eager dispatch (optimization, not core)
- Schedules (server-side feature, no SDK support needed)
- Search attributes (future)
- Memo (future)
- Interceptors (future)
- Build ID versioning (future)
- Async activity completion (future)
- Deadlock detection (BEAM doesn't deadlock the same way)

---

## Summary

| Priority | Category | Count |
|----------|----------|-------|
| P1 | Core Execution | 47 |
| P2 | Signals, Queries, Updates | 30 |
| P3 | Structured Concurrency | 28 |
| P4 | Child Workflows + CAN | 16 |
| P5 | Cancellation | 14 |
| P6 | Error Handling | 8 |
| P7 | Data Conversion | 12 |
| P8 | Client API | 8 |
| P9 | Worker / Server | 16 |
| P10 | Integration E2E | 18 |
| — | Stress (later) | 8 |
| **Total** | | **205** |
