# Temporalex — Complete Test Inventory

All test cases from v0.1.0 (268 passing) plus gap analysis from cross-SDK comparison.
This document is the source of truth for what must be covered in the rewrite.

---

## Part 1: Existing Tests (268 total: 241 unit + 27 E2E)

### 1. Converter (19 unit tests)

Tests for `Temporalex.Converter` — payload serialization/deserialization.

| # | Test | Describe | What it tests |
|---|------|----------|---------------|
| 1 | encodes a string | to_payload/1 | String -> Payload with "json/plain" encoding |
| 2 | encodes an integer | to_payload/1 | Integer JSON-encoded (42 -> "42") |
| 3 | encodes a map | to_payload/1 | Map JSON-encoded with correct key/value pairs |
| 4 | encodes a list | to_payload/1 | List JSON-encoded ([1,2,3]) |
| 5 | encodes nil as binary/null | to_payload/1 | nil -> "binary/null" encoding, empty data |
| 6 | decodes a string payload | from_payload/1 | JSON string payload -> Elixir string |
| 7 | decodes a map payload (atom keys by default) | from_payload/1 | JSON map -> atom-keyed Elixir map |
| 8 | decodes a map payload with explicit string keys | from_payload/1 | `keys: :strings` -> string-keyed map |
| 9 | returns error for invalid JSON | from_payload/1 | Invalid JSON data -> error tuple |
| 10 | decodes binary/null as nil | from_payload/1 | "binary/null" encoding -> nil |
| 11 | decodes binary/plain as raw binary | from_payload/1 | "binary/plain" -> raw binary |
| 12 | returns error for unsupported encoding | from_payload/1 | "protobuf/json" -> error with descriptive message |
| 13 | string round-trips | round-trip | Encode then decode preserves string |
| 14 | map round-trips (atom keys by default) | round-trip | Map round-trips with atom keys |
| 15 | map round-trips (explicit string keys) | round-trip | Map round-trips with `keys: :strings` |
| 16 | list round-trips | round-trip | Mixed-type list round-trips |
| 17 | nil round-trips | round-trip | nil through to_payload/from_payload |
| 18 | round-trips a list of values | to_payloads/from_payloads | Heterogeneous value list |
| 19 | empty list | to_payloads/from_payloads | Empty list round-trips |

### 2. Converter Edge Cases (from bugfix_test.exs) (6 unit tests)

| # | Test | What it tests |
|---|------|---------------|
| 20 | non-JSON-serializable value doesn't crash | Tuple -> payload without crash |
| 21 | PID value doesn't crash | PID -> payload without crash |
| 22 | nil encodes to null payload | nil -> "binary/null" encoding metadata |
| 23 | nested map round-trips correctly | Nested map with lists/booleans round-trips (atom keys) |
| 24 | large binary doesn't crash | 100KB random binary -> payload without crash |
| 25 | empty string round-trips | Empty string round-trips correctly |

### 3. Codec (8 unit tests)

Tests for `Temporalex.Codec` — payload codec chain (encryption/compression).

| # | Test | Describe | What it tests |
|---|------|----------|---------------|
| 26 | nil codec passes through | apply_encode/2 | nil codec returns payload unchanged |
| 27 | single codec transforms payload | apply_encode/2 | Base64Codec encodes data + adds metadata |
| 28 | codec chain applies in order | apply_encode/2 | [PrefixCodec, Base64Codec] applies prefix first, then base64 |
| 29 | error in chain halts | apply_encode/2 | Failing codec halts chain, returns error |
| 30 | nil codec passes through | apply_decode/2 | nil codec returns payload unchanged |
| 31 | single codec transforms payload | apply_decode/2 | Base64Codec decodes back to original |
| 32 | codec chain applies in reverse order | apply_decode/2 | Decode reverses encode order |
| 33 | round-trip preserves data | apply_decode/2 | Encode + decode with codec chain preserves original |

### 4. Error Types & FailureConverter (16 unit tests)

Tests for error structs and `Temporalex.FailureConverter`.

| # | Test | Describe | What it tests |
|---|------|----------|---------------|
| 34 | ActivityFailure formats message | error structs | Message includes activity type and ID |
| 35 | TimeoutError formats message | error structs | Message includes timeout type |
| 36 | CancelledError formats message | error structs | Message includes "Cancelled:" prefix |
| 37 | ApplicationError formats message with type | error structs | Includes `[ValidationError]` in message |
| 38 | ApplicationError formats message without type | error structs | Omits brackets, just "ApplicationError:" |
| 39 | converts ActivityFailure to Failure proto | to_failure/1 | ActivityFailure -> Failure protobuf |
| 40 | converts TimeoutError to Failure proto | to_failure/1 | TimeoutError -> Failure with timeout_failure_info |
| 41 | converts CancelledError to Failure proto | to_failure/1 | CancelledError -> Failure with canceled_failure_info |
| 42 | converts ApplicationError to Failure proto | to_failure/1 | ApplicationError -> Failure with application_failure_info |
| 43 | converts plain string to Failure proto | to_failure/1 | String -> Failure with string as message |
| 44 | converts generic exception to Failure proto | to_failure/1 | RuntimeError -> Failure with message |
| 45 | converts timeout failure back to TimeoutError | from_failure/1 | Failure proto -> TimeoutError round-trip |
| 46 | converts cancelled failure back to CancelledError | from_failure/1 | Failure proto -> CancelledError round-trip |
| 47 | converts application failure back to ApplicationError | from_failure/1 | Failure proto -> ApplicationError with type + non_retryable |
| 48 | converts unknown failure to ApplicationError | from_failure/1 | Failure with no specific info -> fallback ApplicationError |
| 49 | CancelledError formats message | error types (bugfix) | Exception.message/1 includes message text |
| 50 | ApplicationError formats message | error types (bugfix) | Exception.message/1 includes message text |

### 5. ChildWorkflowFailure (5 unit tests)

From bugfix_review2_test.exs — BUG-3 fix verification.

| # | Test | What it tests |
|---|------|---------------|
| 51 | to_failure encodes workflow_type and workflow_id | ChildWorkflowFailure -> Failure with correct fields |
| 52 | to_failure encodes recursive cause | Nested ApplicationError cause encoded as non-nil |
| 53 | from_failure decodes child_workflow_execution_failure_info | Protobuf -> ChildWorkflowFailure struct |
| 54 | from_failure decodes recursive cause chain | ChildWorkflowFailure with TimeoutError cause |
| 55 | round-trip preserves fields | to_failure -> from_failure preserves workflow_type + workflow_id |

### 6. RetryPolicy (12 unit tests)

| # | Test | Describe | What it tests |
|---|------|----------|---------------|
| 56 | struct has sensible defaults | defaults | max_attempts=0, initial_interval=1000, backoff=2.0 |
| 57 | creates with defaults | new/1 | RetryPolicy.new() returns defaults |
| 58 | overrides specific fields | new/1 | Partial overrides keep other defaults |
| 59 | sets all fields | new/1 | All five fields settable |
| 60 | passes through existing struct | from_opts/1 | Struct in, struct out |
| 61 | converts keyword list to struct | from_opts/1 | Keyword list -> RetryPolicy struct |
| 62 | converts defaults to proto | to_proto/1 | Default -> protobuf with Duration structs |
| 63 | converts custom values to proto | to_proto/1 | Custom values -> correct Duration structs |
| 64 | ms_to_duration: exact seconds | to_proto/1 | 5000ms -> {5s, 0ns} |
| 65 | ms_to_duration: sub-second | to_proto/1 | 250ms -> {0s, 250_000_000ns} |
| 66 | ms_to_duration: mixed seconds and millis | to_proto/1 | 1750ms -> {1s, 750_000_000ns} |
| 67 | nil maximum_interval stays nil in proto | to_proto/1 | nil -> nil in proto |

### 7. Workflow.Context (12 unit tests)

| # | Test | Describe | What it tests |
|---|------|----------|---------------|
| 68 | allocates incrementing sequence numbers | next_seq/1 | Returns 0, 1, 2 on successive calls |
| 69 | prepend + flush returns commands in order | add_command/flush_commands | Insertion order preserved, clears after flush |
| 70 | returns nil when no timestamp set | now/1 | nil when current_time not set |
| 71 | returns the workflow time when set | now/1 | Returns DateTime when current_time set |
| 72 | returns false by default | replaying?/1 | Default context not replaying |
| 73 | returns true when replaying | replaying?/1 | is_replaying: true -> true |
| 74 | returns a float between 0 and 1 | random/1 | Float in [0, 1) |
| 75 | is deterministic for same run_id and seq | random/1 | Same context -> same value |
| 76 | returns a string that looks like a UUID | uuid4/1 | Binary with hyphens |
| 77 | replay_results defaults to empty map | new fields | %{} default |
| 78 | worker_pid and workflow_module default to nil | new fields | nil defaults |
| 79 | randomness_seed defaults to nil | new fields | nil default |

### 8. Workflow.Context (from bugfix_test.exs) (5 unit tests)

| # | Test | What it tests |
|---|------|---------------|
| 80 | next_seq increments monotonically | 0, 1, 2 on successive calls |
| 81 | flush_commands returns in correct order and clears | Insertion order, empty after flush |
| 82 | replaying? reflects context state | true/false based on is_replaying |
| 83 | random is deterministic for same run_id and seq | Same context -> same random value |
| 84 | uuid4 is deterministic for same run_id and seq | Same context -> same UUID, contains "-4000-" |

### 9. Workflow Behaviour (8 unit tests)

| # | Test | Describe | What it tests |
|---|------|----------|---------------|
| 85 | workflow module defines __workflow_type__ | Workflow behaviour | Returns fully qualified module name string |
| 86 | workflow run/1 returns {:ok, result} | Workflow behaviour | Correct return value |
| 87 | default handle_signal returns {:noreply, state} | Workflow behaviour | Default signal handler passes state through |
| 88 | custom handle_signal updates state | Workflow behaviour | Custom handler modifies state |
| 89 | custom handle_query returns state data | Workflow behaviour | Custom query handler returns data |
| 90 | activity module defines __activity_type__ | Activity behaviour | Returns fully qualified module name string |
| 91 | activity perform/2 returns {:ok, result} | Activity behaviour | Matching input -> correct greeting |
| 92 | activity perform/2 handles missing input | Activity behaviour | Falls through to default clause |

### 10. Activity Compile-Time (6 unit tests)

| # | Test | What it tests |
|---|------|---------------|
| 93 | module with perform/1 generates perform/2 wrapper | Auto-generates perform/2 wrapper |
| 94 | module with perform/2 compiles without wrapper | No extra wrapper generated |
| 95 | module with both perform/1 and perform/2 raises CompileError | Can't have both |
| 96 | module with neither perform/1 nor perform/2 raises CompileError | Must implement one |
| 97 | perform/1 module has __activity_type__ | Exposes __activity_type__/0 |
| 98 | module-level defaults are stored | __activity_defaults__/0 returns options |

### 11. DSL / defactivity (10 unit tests)

| # | Test | Describe | What it tests |
|---|------|----------|---------------|
| 99 | activity function runs implementation directly | direct mode | No workflow context -> runs body directly |
| 100 | workflow function works end-to-end | direct mode | Chained activities work without stubs |
| 101 | stubs replace activity calls | test mode | run_workflow with stubs replaces real impl |
| 102 | activity calls are recorded for assertions | test mode | get_activity_calls() returns ordered calls |
| 103 | stub_activity works individually | test mode | Register stubs one at a time |
| 104 | stub error propagates through with chain | test mode | Stub {:error, _} short-circuits `with` chain |
| 105 | __temporal_activities__ lists registered activities | module metadata | Lists all defactivity definitions |
| 106 | impl functions are generated | module metadata | __temporal_perform_<name>__ functions exist |
| 107 | activity type strings | module metadata | DSL.activity_type_string/2 formatting |
| 108 | old-style module activities still work with run_workflow | module activities | Legacy Activity modules with stubs |

### 12. DSL Bugfixes (3 unit tests)

| # | Test | What it tests |
|---|------|---------------|
| 109 | defactivity with multiple arguments raises CompileError | BUG-5: multi-arg blocked |
| 110 | defactivity with single argument compiles fine | Single arg works |
| 111 | defactivity with no arguments compiles fine | Zero arg works |

### 13. Workflow API (8 unit tests)

| # | Test | Describe | What it tests |
|---|------|----------|---------------|
| 112 | completes synchronously | no activities | SimpleWorkflow.run(nil) -> {:ok, "done"} |
| 113 | stores and retrieves state in process dictionary | set_state/get_state | API.set_state -> API.get_state round-trip |
| 114 | returns workflow metadata from workflow_info dict | workflow_info/0 | Reads workflow_id, run_id, task_queue, attempt |
| 115 | executes function on first run | side_effect/1 executor mode | Non-replay: executes function, returns 42 |
| 116 | returns error tuple on replay | side_effect/1 executor mode | Replay with recorded result -> error tuple |
| 117 | non-target signals are buffered, not dropped | signal buffering | Non-matching signal stored in buffer |
| 118 | buffered signal is returned immediately on next wait_for_signal | signal buffering | Pre-buffered signal -> immediate return |
| 119 | execute_activity returns replay result without yielding | replay pre-loaded | Replay result at seq 0 -> no blocking |

### 14. Executor / WorkflowTaskExecutor (12 unit tests)

| # | Test | Describe | What it tests |
|---|------|----------|---------------|
| 120 | completes immediately with result | pure workflow | No activities -> complete_workflow_execution |
| 121 | error workflow sends fail command | pure workflow | {:error, _} -> fail_workflow_execution |
| 122 | runner blocks on activity, executor sends schedule command | with activities | Full lifecycle: block -> schedule -> resolve -> block -> resolve -> complete |
| 123 | runner gets replay results immediately | replay | All results pre-loaded -> immediate completion, no schedule commands |
| 124 | partial replay: first replayed, second scheduled | replay | First from history, second scheduled normally |
| 125 | activity where timer expected fails with nondeterminism | nondeterminism | History has timer at seq 0, code calls activity -> fail |
| 126 | timer where activity expected fails with nondeterminism | nondeterminism | History has activity at seq 0, code calls sleep -> fail |
| 127 | crashed runner sends fail command | runner crash | Exception -> fail_workflow_execution with error message |
| 128 | signals are forwarded to runner process | signal forwarding | Signal message -> executor -> runner receives it |
| 129 | uses task_queue as ID for multiple servers | Server.child_spec | {Temporalex.Server, task_queue} as child spec ID |
| 130 | sets shutdown timeout for NIF drain | Server.child_spec | Shutdown timeout = 35,000ms |
| 131 | requires task_queue | Server.child_spec | Missing :task_queue -> ArgumentError |

### 15. Features (16 unit tests)

| # | Test | Describe | What it tests |
|---|------|----------|---------------|
| 132 | raises ContinueAsNew exception | continue_as_new | API.continue_as_new raises ContinueAsNew |
| 133 | carries workflow type and task queue from context | continue_as_new | Exception carries context defaults |
| 134 | allows overriding workflow type and task queue | continue_as_new | Options override context |
| 135 | with no args | continue_as_new | No arguments -> empty args list |
| 136 | builds start_child_workflow_execution command and resolves | execute_child_workflow | Command with workflow_id + workflow_type, resolves on result |
| 137 | child workflow replays from history without blocking | execute_child_workflow | Pre-loaded replay -> immediate return |
| 138 | adds upsert command via executor | upsert_search_attributes | Completes without error |
| 139 | ContinueAsNew is a proper exception | error types | Implements Exception, message = "continue_as_new" |
| 140 | ChildWorkflowFailure formats message | error types | "Child workflow failed" + workflow type |
| 141 | returns true when patch is pre-notified | patched? | Patch ID in context -> true |
| 142 | returns true on first execution via executor | patched? | Non-replay + executor -> true + set_patch_marker |
| 143 | deprecate_patch emits deprecated marker | patched? | Completes without error |
| 144 | returns false by default | cancelled? | No cancellation flag -> false |
| 145 | returns true after cancel flag set | cancelled? | __temporal_cancelled__ set -> true |
| 146 | replays from history without blocking | execute_local_activity | Pre-loaded replay result -> immediate return |
| 147 | stubs work for local activities too | execute_local_activity | stub_activity + assert_activity_called work |

### 16. random/0 and uuid4/0 (5 unit tests)

From bugfix_review2_test.exs.

| # | Test | What it tests |
|---|------|---------------|
| 148 | random returns deterministic float via executor | GenServer.call(executor, :random) -> float in [0, 1) |
| 149 | random is deterministic for same run_id and seq | Same run_id -> same random values |
| 150 | uuid4 returns deterministic UUID v4 string | 36-char string with version nibble "4" |
| 151 | uuid4 is deterministic for same run_id and seq | Same run_id -> same UUIDs |
| 152 | random and uuid4 accessible from workflow code | Process-dictionary executor -> workflow completion |

### 17. Bugfix Verifications (7 unit tests)

| # | Test | What it tests |
|---|------|---------------|
| 153 | side_effect returns error tuple on replay instead of crashing | FIX-1: no executor crash |
| 154 | side_effect executes function normally on first run | FIX-1: normal execution works |
| 155 | stale activity result after cancel is discarded | FIX-2: stale ref detected |
| 156 | send_completion calculates real duration from activation_start | FIX-4: non-zero duration |
| 157 | nil activation_start produces zero duration | FIX-4: inline completions = 0 |
| 158 | workflow returning {:error, string} produces error tuple | Error string propagation |
| 159 | workflow returning {:error, exception} preserves message | Exception struct preserved |

### 18. Signal & Cancel Handling (6 unit tests)

From bugfix_test.exs.

| # | Test | What it tests |
|---|------|---------------|
| 160 | patches received during signal wait are stored | :notify_has_patch stored during wait_for_signal |
| 161 | cancel_workflow received during signal wait sets flag | :cancel_workflow sets __temporal_cancelled__ |
| 162 | cancelled? returns false before cancel | Fresh context -> false |
| 163 | cancelled? returns true after flag set | Manual flag set -> true |
| 164 | patched? returns true when patch is pre-notified | Pre-loaded patch ID -> true |
| 165 | multiple pre-notified patches tracked independently | Multiple patches tracked independently |

### 19. Connection (7 unit tests)

| # | Test | Describe | What it tests |
|---|------|----------|---------------|
| 166 | missing :name raises ArgumentError | start_link/1 | Requires :name option |
| 167 | rejects garbage address | address validation | "not-a-url" -> error |
| 168 | rejects address without scheme | address validation | "localhost:7233" rejected |
| 169 | accepts http address | address validation | http:// passes, starts process |
| 170 | accepts https address | address validation | https:// passes, starts process |
| 171 | returns not_connected when runtime is nil | get/1 | Connection.get/1 returns state map |
| 172 | address defaults to localhost:7233 | defaults | Default address + namespace |

### 20. Client (10 unit tests)

| # | Test | Describe | What it tests |
|---|------|----------|---------------|
| 173 | dead PID returns error tuple | resolve_connection | Dead PID -> {:error, _} |
| 174 | unregistered atom returns error tuple | resolve_connection | Unregistered name -> {:error, _} |
| 175 | map connection resolves without crash | resolve_connection | describe/list return {:error, _} for bad conn |
| 176 | keyword list args detected as opts mistake | start_workflow validation | Keyword list as args -> ArgumentError |
| 177 | auto-generated IDs are unique | workflow ID generation | __workflow_type__ contains module name |
| 178 | returns error for dead connection | describe_workflow | Dead conn -> {:error, _} |
| 179 | returns error for dead connection | list_workflows | Dead conn -> {:error, _} |
| 180 | raises when keyword list is passed as args | start_workflow (client_test) | ArgumentError on keyword args |
| 181 | returns error tuple for dead PID | resolve_connection (client_test) | signal_workflow dead PID -> error |
| 182 | returns error tuple for unregistered atom | resolve_connection (client_test) | signal_workflow unregistered -> error |

### 21. Supervisor (5 unit tests)

| # | Test | Describe | What it tests |
|---|------|----------|---------------|
| 183 | connection_name/1 derives correct module name | Temporalex as Supervisor | Appends .Connection |
| 184 | init/1 builds correct child specs | Temporalex as Supervisor | :rest_for_one, 2 children |
| 185 | init/1 uses defaults for optional fields | Temporalex as Supervisor | Default address, namespace, empty lists |
| 186 | init/1 raises when task_queue is missing | Temporalex as Supervisor | ArgumentError |
| 187 | start_link raises when name is missing | Temporalex as Supervisor | ArgumentError |

### 22. Validation (10 unit tests)

| # | Test | Describe | What it tests |
|---|------|----------|---------------|
| 188 | rejects non-existent module | workflow registration | Non-existent module -> "could not be loaded" |
| 189 | rejects module without run/1 | workflow registration | Enum -> "does not export run/1" |
| 190 | rejects invalid workflow spec | workflow registration | Integer 123 -> "Invalid workflow spec" |
| 191 | rejects non-existent module | activity registration | Non-existent module -> "could not be loaded" |
| 192 | rejects module without activity markers | activity registration | Enum -> "not a valid activity" |
| 193 | task_queue is required | missing required options | No :task_queue -> "requires :task_queue" |
| 194 | rejects max_concurrent_workflow_tasks = 0 | config validation | Zero -> ArgumentError |
| 195 | rejects max_concurrent_workflow_tasks = -1 | config validation | Negative -> ArgumentError |
| 196 | rejects max_concurrent_activity_tasks = 0 | config validation | Zero -> ArgumentError |
| 197 | rejects non-integer max_concurrent_workflow_tasks | config validation | "five" -> ArgumentError |

### 23. Interceptor (8 unit tests)

| # | Test | Describe | What it tests |
|---|------|----------|---------------|
| 198 | empty chain calls final directly | chain_client/3 | No interceptors -> direct call |
| 199 | single interceptor wraps call | chain_client/3 | RecordingInterceptor wraps + sends message |
| 200 | interceptor chain applies in order | chain_client/3 | Enriching then Recording in declared order |
| 201 | interceptor can short-circuit | chain_client/3 | BlockingInterceptor -> {:error, :blocked} |
| 202 | noop interceptor passes through | chain_client/3 | NoopInterceptor passes unchanged |
| 203 | interceptor wraps activity execution | chain_activity/3 | RecordingInterceptor wraps activity call |
| 204 | interceptor wraps workflow execution | chain_workflow/3 | RecordingInterceptor wraps workflow call |
| 205 | enriching interceptor modifies args | chain_workflow/3 | EnrichingInterceptor adds :enriched key |

### 24. Testing Utilities (19 unit tests)

| # | Test | Describe | What it tests |
|---|------|----------|---------------|
| 206 | runs a simple workflow | run_workflow/2,3 | SimpleWorkflow -> {:ok, "Hello, Alice!"} |
| 207 | workflow state is accessible | run_workflow/2,3 | get_workflow_state() returns set_state value |
| 208 | failing workflow returns error | run_workflow/2,3 | {:error, "broken"} propagates |
| 209 | workflow with patches | run_workflow/2,3 | patches: ["v2-algo"] -> patched? returns true |
| 210 | runs a perform/1 activity | run_activity/2 | SimpleActivity -> {:ok, 10} |
| 211 | runs a perform/2 activity with context | run_activity/2 | ContextActivity -> {:ok, 6} |
| 212 | sets up process dictionary | workflow_context/1 | Sets workflow_info, state, patches, cancelled |
| 213 | accepts pre-notified patches | workflow_context/1 | patches: ["p1", "p2"] -> MapSet |
| 214 | auto-generates unique IDs | workflow_context/1 | Two calls -> different workflow_id + run_id |
| 215 | workflow with stubbed activities via run_workflow option | activity stubs | activities: %{...} stubs execution |
| 216 | assert_activity_called tracks which activities ran | activity stubs | Assertion passes after stubbed call |
| 217 | assert_activity_called with specific input | activity stubs | Matches specific input |
| 218 | get_activity_calls returns calls in order | activity stubs | Ordered {module, input} tuples |
| 219 | stub_activity registers stubs individually | activity stubs | Register one at a time |
| 220 | stubbed activity error propagates as MatchError | activity stubs | {:error, _} in stub -> MatchError |

### 25. Telemetry (4 unit tests)

| # | Test | What it tests |
|---|------|---------------|
| 221 | workflow events are emitted | workflow_start + workflow_stop telemetry events |
| 222 | activity events are emitted | activity_start + activity_stop telemetry events |
| 223 | activation event includes job and command counts | worker_activation with duration, job_count, command_count |
| 224 | OpenTelemetry setup attaches handlers | setup() returns :ok |

### 26. Ease of Use (12 unit tests)

| # | Test | Describe | What it tests |
|---|------|----------|---------------|
| 225 | rejects zero duration | sleep/1 validation | sleep(0) -> ArgumentError "must be positive" |
| 226 | rejects negative duration | sleep/1 validation | sleep(-1000) -> ArgumentError |
| 227 | rejects non-integer | sleep/1 validation | sleep(1.5) -> ArgumentError |
| 228 | rejects string | sleep/1 validation | sleep("5000") -> ArgumentError |
| 229 | pre-buffered signal consumed by wait_for_signal | send_signal/2 | send_signal -> wait_for_signal consumes it |
| 230 | workflow with pre-buffered signal completes | send_signal/2 | signals: option pre-buffers |
| 231 | multiple signals buffered in order | send_signal/2 | Insertion order preserved |
| 232 | stub replaces executor call | child workflow stubs | child_workflows: stubs replace real exec |
| 233 | child workflow calls are recorded | child workflow stubs | get_child_workflow_calls() returns module + args |
| 234 | assert_child_workflow_called succeeds | child workflow stubs | Assertion helper works |
| 235 | stub_child_workflow works after workflow_context | child workflow stubs | Register stub individually |
| 236 | includes encoding and data size on failure | from_payload! errors | RuntimeError with encoding + data size |

### 27. Server Race Conditions (5 unit tests)

| # | Test | Describe | What it tests |
|---|------|----------|---------------|
| 237 | stale ref not in activity_tasks is detected | cancel duplicate completion | Stale ref -> not found |
| 238 | cancel removes from activity_tasks before result arrives | cancel duplicate completion | Late result discarded |
| 239 | last_completing_run_id tracks most recent completion | completion attribution | nil -> run-1 -> nil -> run-2 |
| 240 | concurrent completions overwrite (advisory field) | completion attribution | Last write wins |
| 241 | pending_activations pop prevents double processing | executor timeout race | First pop returns entry, second returns nil |

### 28. E2E Tests (27 tests, all @moduletag :e2e)

Tests against real Temporal dev server.

| # | Test | Describe | What it tests |
|---|------|----------|---------------|
| 242 | completes with result | pure workflow | Full stack: Elixir -> NIF -> Rust -> gRPC -> Temporal |
| 243 | error workflow returns failure | pure workflow | {:error, reason} surfaces through CLI |
| 244 | single activity | activities | Activity execution round-trip |
| 245 | chained activities | activities | A -> B chain completes |
| 246 | sleep then activity | timers | Timer fire -> activity execution |
| 247 | workflow waits for signal then completes | signals | Block on signal -> receive via CLI -> complete |
| 248 | workflow continues until counter reaches threshold | continue-as-new | Counter 0 -> 3 across continuations |
| 249 | start_workflow and get_result | client API | Elixir Client start + get_result |
| 250 | multiple workflows complete on same queue | concurrent workflows | 5 concurrent -> all correct results |
| 251 | Temporalex supervisor starts connection + server | supervisor tree | Full supervision tree + workflow |
| 252 | activity that exceeds start-to-close timeout fails | activity timeout | 2s timeout, 10s activity -> failure |
| 253 | activity retries and eventually succeeds | activity retry | Fails twice, succeeds on attempt 3 |
| 254 | cancelled workflow terminates | workflow cancellation | CLI cancel -> status Canceled |
| 255 | activity is cancelled when workflow is cancelled | workflow cancellation | Cancel propagates to long-running activity |
| 256 | query returns workflow state | workflow query | set_state -> query returns it |
| 257 | two different workflow types on same queue | multiple workflow types | Double + AddTen both work |
| 258 | activity heartbeats during execution | activity heartbeat | Heartbeat prevents timeout |
| 259 | server stops cleanly while activity is in-flight | graceful shutdown | GenServer.stop drains cleanly |
| 260 | supervisor shutdown is graceful | graceful shutdown | Supervisor.stop orderly |
| 261 | second start with same ID while running returns error | workflow ID reuse | Idempotent by ID |
| 262 | retries and eventually succeeds | activity retry with exhaustion | File-based counter, max_attempts=3 |
| 263 | signals delivered in FIFO order | signal ordering | A, B, C -> "A-B-C" |
| 264 | query returns state from completed workflow | query after complete | Post-completion query works |
| 265 | processes multiple items and collects results | parallel activities | 5 items -> 5 "processed-X" results |
| 266 | parent starts child and gets result | child workflow | execute_child_workflow -> child result |
| 267 | compensation runs on failure | saga pattern | Step2 fails -> compensate_one runs -> "rolled-back" |
| 268 | stops retrying immediately | non-retryable error | ApplicationError non_retryable -> max 1-2 attempts |

---

## Part 2: Gap Analysis — Tests We Need But Don't Have

From cross-SDK comparison (Go ~200+, Python ~450+, TypeScript ~461).

### E2E Gaps (51 missing)

#### Workflow Lifecycle

| # | Test | Priority | Notes |
|---|------|----------|-------|
| E2 | Workflow with complex args (nested maps, lists, nil) | Medium | Serialization round-trip through server |
| E4 | Workflow panic/unhandled exception returns failure | High | Should not crash the server |
| E6 | Workflow execution timeout fires | High | All SDKs test this |
| E7 | Workflow run timeout fires | High | All SDKs test this |
| E10 | Start workflow with explicit ID | Medium | Verify ID used, not generated |
| E11 | Describe workflow (status, type) after start | Medium | describe_workflow NIF |
| E12 | Workflow with empty args (nil input) | Low | Edge case |

#### Activities

| # | Test | Priority | Notes |
|---|------|----------|-------|
| E16 | Activity schedule-to-close timeout fires | Medium | Different timeout semantic |
| E17 | Activity schedule-to-start timeout fires | Medium | No worker picks up task |
| E21 | Activity retry with custom backoff coefficient | Low | Verify actual delay |
| E23 | Activity heartbeat timeout detection | High | No heartbeat = failure |
| E24 | Activity heartbeat preserves details across retries | High | Go/Python test extensively |
| E26 | Local activity execution | Medium | Not visible in Temporal UI |
| E27 | Local activity timeout | Medium | Local timeout enforcement |

#### Timers

| # | Test | Priority | Notes |
|---|------|----------|-------|
| E29 | Multiple sequential sleeps | Medium | Timer chaining |
| E30 | Sleep(0) or very short sleep | Low | Immediate timer fire |

#### Signals

| # | Test | Priority | Notes |
|---|------|----------|-------|
| E33 | Signal sent before workflow reaches wait_for_signal | High | Signal buffered |
| E34 | Multiple signals of different types | Medium | Dispatch by name |
| E35 | Signal with complex payload | Medium | Serialization path |
| E36 | Signal to completed workflow | High | Should error, not crash |

#### Queries

| # | Test | Priority | Notes |
|---|------|----------|-------|
| E38 | Query with arguments | Medium | Args decoded |
| E39 | Query to unregistered handler name | Medium | Should error |
| E40 | Query while workflow is processing | Medium | Consistency |

#### Cancellation

| # | Test | Priority | Notes |
|---|------|----------|-------|
| E44 | Cancel workflow, workflow performs cleanup then exits | High | Graceful cancellation |
| E45 | Terminate workflow (hard kill) | Medium | terminate_workflow NIF |
| E46 | Cancel workflow waiting on signal | Medium | Cancel + signal interaction |

#### Continue-as-New

| # | Test | Priority | Notes |
|---|------|----------|-------|
| E48 | Continue-as-new with different args | Medium | New execution, new args |
| E49 | Continue-as-new preserves task_queue | Medium | Same queue |
| E50 | Continue-as-new with override task_queue | Medium | Move to different queue |

#### Child Workflows

| # | Test | Priority | Notes |
|---|------|----------|-------|
| E52 | Child workflow fails, parent gets error | High | Error propagation |
| E53 | Cancel parent, child also cancelled | High | Cascading cancellation |
| E54 | Parent sends signal to child | Medium | Cross-workflow signals |

#### Versioning / Patching

| # | Test | Priority | Notes |
|---|------|----------|-------|
| E55 | Workflow with patched? takes new path | High | First execution with patch |
| E56 | Replay of pre-patch workflow takes old path | High | Backward compatibility |
| E57 | deprecate_patch allows cleanup | Medium | Patch lifecycle |

#### Client API

| # | Test | Priority | Notes |
|---|------|----------|-------|
| E59 | signal_workflow delivers to running workflow | Medium | Client signal path |
| E60 | query_workflow returns handler result | Medium | Client query path |
| E61 | cancel_workflow stops running workflow | Medium | Client cancel path |
| E62 | terminate_workflow hard-kills | Medium | Client terminate path |
| E63 | get_result on already-completed workflow | Medium | Historical result |
| E64 | get_result with timeout | Low | Client-side timeout |

#### Supervisor Integration

| # | Test | Priority | Notes |
|---|------|----------|-------|
| E66 | Connection dies, server restarts and reconnects | High | :rest_for_one recovery |
| E67 | Server crash during workflow, workflow retried | High | OTP fault tolerance |

#### Shutdown

| # | Test | Priority | Notes |
|---|------|----------|-------|
| E69 | Shutdown with in-flight workflow completes cleanly | Medium | Workflow drain |

#### Observability

| # | Test | Priority | Notes |
|---|------|----------|-------|
| E71 | Telemetry events fire for workflow start/stop (E2E) | Low | End-to-end telemetry |
| E72 | Telemetry events fire for activity start/stop (E2E) | Low | End-to-end telemetry |
| E73 | Logger metadata includes workflow_id, run_id | Low | Structured logging |

#### Real-World Patterns

| # | Test | Priority | Notes |
|---|------|----------|-------|
| E75 | Long-running workflow: sleep(days) + signal to wake | Low | Production pattern |
| E76 | Fan-out/fan-in with parallel | Low | Parallel execution |
| E77 | Retry storm respects max_attempts | Low | Backpressure |
| E78 | DSL workflow runs end-to-end | Medium | defactivity through real server |

### Unit Test Gaps (70 missing)

#### Converter

| # | Test | Priority |
|---|------|----------|
| U3 | Encode/decode float | Low |
| U4 | Encode/decode boolean | Low |
| U6 | Nested map (3 levels deep) | Medium |
| U7 | List of maps | Low |
| U8-U9 | Empty map/list | Low |
| U10 | Large payload (1MB+) | Medium |
| U11-U12 | UTF-8 vs non-UTF-8 binary | Medium |
| U16-U18 | Unknown encoding, empty data, no metadata | Medium |
| U19 | Mixed success/failure in from_payloads | Low |
| U20 | Unicode round-trip (emoji, CJK) | Medium |

#### FailureConverter

| # | Test | Priority |
|---|------|----------|
| U22 | TimeoutError all 4 timeout types | Medium |
| U25-U26 | ApplicationError non_retryable + type flags | Medium |
| U28 | Nondeterminism error encoding | Medium |
| U29 | Nested failure chain | Medium |
| U32 | Failure with nil/empty message | Low |

#### Error Types

| # | Test | Priority |
|---|------|----------|
| U34 | ActivityFailure with nil fields | Low |
| U37 | ContinueAsNew preserves all fields | Low |
| U40 | Errors implement Exception protocol (raise/rescue) | Medium |

#### Context

| # | Test | Priority |
|---|------|----------|
| U55-U56 | random different for different seq, boundary check | Medium |
| U58-U59 | uuid4 v4 format validation, different for different seq | Medium |
| U60-U62 | from_init parsing (all fields, missing parent, timestamp) | Medium |

#### Workflow API

| # | Test | Priority |
|---|------|----------|
| U65 | execute_activity merges module defaults with call-site opts | Medium |
| U67 | execute_local_activity uses local flag | Medium |
| U85 | get_executor! raises with helpful message | Low |

#### Executor

| # | Test | Priority |
|---|------|----------|
| U99 | Multiple activities chained (A -> B -> done) | Medium |
| U100-U101 | Timer command + timer replay | Medium |
| U102-U103 | build_schedule_activity encodes timeouts + retry_policy | Medium |
| U104-U106 | build_complete/fail/continue_as_new | Medium |
| U108 | ContinueAsNew exception caught, command built | Medium |
| U110 | Nondeterminism: child workflow where activity expected | Low |

#### Server (Unit)

| # | Test | Priority |
|---|------|----------|
| U114-U115 | build_activity_map (DSL + legacy) | Medium |
| U117-U126 | dispatch_activation, handle_queries, reject_updates, extract results | Medium |

#### DSL

| # | Test | Priority |
|---|------|----------|
| U134-U138 | defactivity option handling (timeouts, retry, task_queue) | Medium |

#### Activity

| # | Test | Priority |
|---|------|----------|
| U151-U154 | Activity.Context parsing, heartbeat encoding, dead worker | Medium |

#### Client

| # | Test | Priority |
|---|------|----------|
| U158-U166 | ID generation, encode_args, resolve_connection, decode_query | Medium |

### Cross-SDK Conformance (33 scenarios)

Must-pass core conformance from `temporalio/features` repo:

| # | Feature | Category |
|---|---------|----------|
| C1-C4 | Activity basic, cancel, retry; Child workflow result | Core |
| C5-C6 | Child workflow signal; Continue-as-new same type | Core |
| C7-C11 | Data converter (binary, protobuf, json, empty, failure) | Core |
| C12-C16 | Query (successful, timeout, bad args, bad type, bad return) | Core |
| C17-C20 | Signal (basic, signal-with-start, external, activities in handler) | Core |
| C21-C27 | Updates (basic, activities, async, dedup, reject, replay, restart) | Future |
| C28-C32 | Schedules (basic, cron, pause, trigger, backfill) | Future |
| C33 | Telemetry metrics | Future |

### Stress / Load (8 scenarios)

| # | Test | Notes |
|---|------|-------|
| S1 | 100 concurrent workflows | No resource leaks |
| S2 | 50 sequential activities | Long history |
| S3 | 10 workflows x 10 parallel activities | Fan-out pressure |
| S4 | 100 signals in 1 second | Mailbox pressure |
| S5 | 1MB payload round-trip | Serialization perf |
| S6 | 10 continue-as-new chains | CAN chain |
| S7 | Shutdown under 50 in-flight activities | Graceful drain |
| S8 | Connection drop + reconnect during workflow | Network resilience |

---

## Part 3: New Tests Required by Programming Model (Gist)

These are new test categories that don't exist in v0.1 because the features are new.

### API.receive

| # | Test | Priority |
|---|------|----------|
| PM1 | receive blocks workflow, exits on {:stop, state} | High |
| PM2 | receive with signal handler dispatches by name | High |
| PM3 | receive with update handler returns reply | High |
| PM4 | receive timeout returns {:timeout, state} | High |
| PM5 | receive processes multiple messages before stop | High |
| PM6 | receive with no matching handler ignores message | Medium |
| PM7 | nested receive blocks (disallowed, should error) | Medium |
| PM8 | receive preserves state across handler invocations | High |
| PM9 | receive with both signal and update handlers | Medium |
| PM10 | receive exits when all async handlers complete | High |

### Async Handlers

| # | Test | Priority |
|---|------|----------|
| PM11 | {:async, fn, state} spawns background work | High |
| PM12 | async handler return value becomes update reply | High |
| PM13 | receive loop continues dispatching while async runs | High |
| PM14 | API.update_state(fn) atomically transforms state | High |
| PM15 | multiple concurrent async handlers | Medium |
| PM16 | async handler can call activities | High |
| PM17 | async handler can call parallel | Medium |
| PM18 | nested async (disallowed, should error) | Medium |
| PM19 | receive cannot nest inside async (should error) | Medium |
| PM20 | all async handlers must complete before receive exits | High |

### API.parallel

| # | Test | Priority |
|---|------|----------|
| PM21 | parallel executes all branches | High |
| PM22 | parallel returns results in input order | High |
| PM23 | one branch fails, others complete, error captured | High |
| PM24 | parallel with activities in each branch | High |
| PM25 | nested parallel | Medium |
| PM26 | parallel cannot contain receive (should error) | Medium |
| PM27 | parallel cannot contain async (should error) | Medium |
| PM28 | empty parallel returns empty list | Low |

### Updates (new message type)

| # | Test | Priority |
|---|------|----------|
| PM29 | update handler returns {:reply, response, state} | High |
| PM30 | update with validator (accepts) | High |
| PM31 | update with validator (rejects) | High |
| PM32 | update rejected outside receive block | High |
| PM33 | update tracking (synchronous completion) | Medium |
| PM34 | async update handler | High |

### Published State & Queries

| # | Test | Priority |
|---|------|----------|
| PM35 | API.publish_state makes state visible to queries | High |
| PM36 | handle_query/3 reads published state | High |
| PM37 | published state persists across receive blocks | Medium |
| PM38 | published state independent from receive state | Medium |

### State Model (three-layer)

| # | Test | Priority |
|---|------|----------|
| PM39 | local variables private to run/1 | High |
| PM40 | receive state scoped to receive block | High |
| PM41 | published state vs receive state vs local vars are independent | High |

### Nesting Rules Enforcement

| # | Test | Priority |
|---|------|----------|
| PM42 | receive inside run/1 works | High |
| PM43 | parallel inside run/1 works | High |
| PM44 | async inside run/1 is disallowed | Medium |
| PM45 | receive inside parallel is disallowed | Medium |
| PM46 | async inside parallel is disallowed | Medium |

### API.patched?

| # | Test | Priority |
|---|------|----------|
| PM47 | patched? returns true on first execution | High |
| PM48 | patched? returns true on replay when marker exists | High |
| PM49 | patched? returns false on replay when no marker | High |

---

## Summary

| Category | Count |
|----------|-------|
| Existing tests (v0.1.0) | 268 |
| E2E gaps | 51 |
| Unit test gaps | 70 |
| Cross-SDK conformance | 33 |
| Stress/load | 8 |
| New programming model tests | 49 |
| **Total documented** | **479** |
