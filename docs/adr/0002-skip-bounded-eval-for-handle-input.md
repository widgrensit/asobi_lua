# ADR 0002: Skip bounded_eval for handle_input

Date: 2026-05-05

## Status

Accepted.

## Context

Every Lua callback in `asobi_lua_match` and `asobi_lua_world` runs through
`asobi_lua_loader:bounded_eval/2`: a `spawn_opt` with `monitor` and
`max_heap_size: kill => true`, the function runs in the child, the parent
receives the result via message-passing, and a wall-clock timeout kills
the child if it overruns.

This protects the gen_server from runaway scripts (infinite loops, heap
blow-ups). It exists for good reasons documented in
`guides/security-trust-model.md`.

It also has a per-call cost. `spawn_opt` with `monitor` + `max_heap_size`
is on the order of 30-50 µs even on idle hardware. Combined with the
message round-trip and the demonitor on the way out, every Lua call
pays roughly 40-80 µs of pure overhead before the actual Lua work starts.

For `tick/1` the overhead is amortized over the tick's actual work
(NPC simulation, world updates) — 80 µs is rounding error against a
1-5 ms tick.

For `handle_input/3` the picture is different. A WS-arriving player input
is small: a position delta, an action enum, a few bytes of state to
update. The actual Lua work is on the order of 50-100 µs. The bounded_eval
overhead is comparable to the work itself — we're spending nearly half
our time on safety machinery for a call whose worst-case work is
intrinsically bounded by message size.

Measurement at 200 players × 10 Hz = 2000 inputs/sec showed
`asobi-bench-asobi-1` sitting at ~250% CPU. The local bench failed to
demonstrate a clean win from the encode-once optimization (asobi ADR
0001) because Luerl-spawn churn from per-input bounded_eval dominated
the savings. See `asobi-bench/results/2026-05-05-post-fix1.md` for the
numbers.

## Decision

Stop spawning a child process per `handle_input/3` call. Use
`asobi_lua_loader:call/3` (which wraps `luerl:call_function/3` in an
internal try/catch and returns `{ok, _, _} | {error, {lua_error, _} |
{call_failed, _}}`) instead of `call/4` (which adds `bounded_eval` on
top).

The bridge code's existing `{error, _}` clause already logs a warning
and returns `{ok, State}` for any Luerl error, so swapping `call/4` →
`call/3` is a one-line change with no new error-handling needed. Bad
input shapes still log and drop the input.

Keep `bounded_eval` for `init/1`, `tick/1`, `get_state/{1,2}`,
`vote_requested/1`, `vote_resolved/3`, and the world-side
equivalents — those run script-author code in contexts where wall-clock
or heap protection still matters.

Apply the same change to `asobi_lua_match_shared:get_state/1`? No.
`get_state` runs once per tick, not per input. Spawn cost is amortized.
Leave it alone.

Apply the same change to `asobi_lua_world:handle_input/3`? Yes — same
reasoning. Per-input frequency, bounded work per call.

## Consequences

- Eliminates ~40-80 µs of overhead per WS input message. At 2000
  inputs/sec the saving is on the order of 80-160 ms of CPU per second
  freed up across the BEAM. Re-bench after the change to verify p99
  improvement at 200 players.
- A buggy or malicious `handle_input` can no longer be wall-clock-killed.
  An infinite loop in handle_input now hangs the match server until the
  caller's gen_server timeout (5s default) trips, then the match server
  crashes and is restarted by the match supervisor. The blast radius is
  one match, not the whole node.
- A heap-allocating handle_input is no longer caught by `max_heap_size`
  per call. The persistent Luerl state is held in the match server
  process, which has its own heap and OS-level limits via VM args.
  Pathological allocation in handle_input would grow the match server
  process heap until OOM kill — same outcome as today, just no per-call
  cap.
- The trust model gets sharper: `tick/1` is the load-bearing isolation
  point. `handle_input/3` is not a sandbox boundary; it's a hot path for
  trusted-author scripts. Documented in `guides/security-trust-model.md`.
- The "blast radius is one match" claim is asserted in the ADR but only
  partially pinned by tests. The match-bridge and world-bridge contract
  tests prove infinite-loop handle_input does not self-terminate; an
  end-to-end CT suite that drives an input through the match supervisor,
  asserts the gen_server times out, and asserts only the affected match
  restarts is a follow-up.

## Alternatives considered

- **Pool of long-lived worker processes per match** — one or more workers
  hold the Lua state, the match server messages them. Eliminates per-call
  spawn AND keeps timeout protection. Rejected as a much larger change
  with state-ownership complications (Luerl state mutates on every call;
  shared ownership across processes needs message-passing of the state
  itself, which is just as expensive as spawning).
- **Batch inputs and run them in one Lua call per tick** — drain the
  input queue at tick time, call a `handle_inputs(queue, state)` Lua
  function that loops. Bigger API surface (new optional Lua function
  shape), changes input ordering semantics (currently per-input
  immediate; batched would be tick-quantized). Possibly a future
  change but not for the first cut.
- **Lower the `INPUT_TIMEOUT` to something tiny (e.g. 5 ms) so killed
  workers cost less** — doesn't help; spawn overhead is the same
  regardless of timeout, and 5 ms timeout would false-fire on slow
  scripts that aren't actually broken.
- **Add a Luerl-level instruction-count budget** — Luerl doesn't expose
  one. Implementing it would mean modifying Luerl itself, out of scope.
