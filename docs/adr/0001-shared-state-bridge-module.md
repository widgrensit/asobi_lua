# ADR 0001: Shared-state Lua bridge as a separate module

Date: 2026-05-05

## Status

Accepted. Shipped in asobi_lua#41 alongside asobi#117.

Retroactive ADR — written after merge.

## Context

The asobi behaviour gained an optional `get_state/1` callback for
shared-payload broadcasts (asobi ADR 0001). For pure Erlang games the
callback dispatch is a static export check: implement `get_state/1` and
the match server picks the shared path.

For Lua games the dispatch is harder. The bridge module is always
`asobi_lua_match`; whether to use shared or per-player is a property of
the *user's Lua script*, not the bridge. Two complications:

1. Erlang exports are static. If `asobi_lua_match` exports `get_state/1`,
   the match server takes the shared path for *every* Lua match — including
   existing scripts that defined `function get_state(player_id, state)`,
   which would break (Lua binds the single arg to `player_id`, leaving
   `state` nil → field access crash → empty payload to all players).
2. Lua functions don't have arity. `function get_state(player_id, state)`
   called with one arg silently makes `state = nil`. We can't auto-detect
   the script's intent.

## Decision

Ship a second bridge module `asobi_lua_match_shared` that:

- Delegates `init/1`, `join/2`, `leave/2`, `handle_input/3`, `tick/1`,
  `vote_*` directly to `asobi_lua_match` (no duplicated work).
- Implements its own `get_state/1` that calls the Lua script's
  `get_state(state)` (one argument) and returns the shared map.
- Does NOT export `get_state/2`.

Selection is opt-in via `state_strategy = "shared"` in the match script's
globals. `asobi_lua_config` reads this and adds `state_strategy => shared`
to the mode config map. `asobi_game_modes`/`asobi_matchmaker` then resolve
`{lua, Script}` + `state_strategy => shared` to `asobi_lua_match_shared`
instead of `asobi_lua_match`.

## Consequences

- Existing scripts (`{lua, Script}` with no `state_strategy`) keep
  resolving to `asobi_lua_match` and the per-player path. Zero behaviour
  change. Backward compatible.
- Two bridge modules to maintain. Most callbacks are one-line delegates.
  Acceptable cost for the explicitness — there is no runtime ambiguity
  about which path a given match is on.
- The selection point lives in one place (the Lua script declares its
  intent). No silent fallback, no auto-detection guessing wrong.

## Alternatives considered

- **Always export `get_state/1` from `asobi_lua_match` and route the
  per-player path through it by passing a sentinel** — would require
  every existing Lua script to handle a sentinel argument. Breaks
  backward compatibility silently.
- **Auto-detect the script's `get_state` arity** — Lua doesn't expose
  arity reliably (`debug.getinfo` is gated by the sandbox; even if
  enabled, it returns `nparams` which is 0 for vararg functions and
  unreliable across Lua/Luerl versions).
- **A new optional `is_shared_state/1` callback in asobi_match** — would
  let one bridge module expose both paths. Considered but rejected: adds
  a callback to the public asobi behaviour for what is really an asobi_lua
  internal concern. The two-bridge approach keeps the asobi API minimal.
- **A config flag in `game_modes` instead of a Lua global** — would split
  the source of truth. Putting the flag in the script keeps the script
  self-describing: opening match.lua shows the broadcast strategy, no
  need to cross-reference `sys.config`.
