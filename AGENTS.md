# AGENTS.md

Working agreement for agents and contributors on **asobi_lua** - the Lua
scripting runtime for the [asobi](https://github.com/widgrensit/asobi) game
backend. A thin OTP layer that embeds Luerl (Lua 5.3 on the BEAM) and exposes
the `game.*` Lua API so a whole multiplayer backend can be written in `.lua`
files, hot-reloaded in place with no restart. Apache-2.0, pre-1.0.

## Where this sits (three repos, never conflated)

- **asobi** (public library, Hex) - the game backend itself: auth, matches,
  matchmaker, leaderboards, economy, social, worlds, storage. Erlang authors
  depend on this directly.
- **asobi_lua** (this repo, public, `ghcr.io/widgrensit/asobi_lua`) - wraps
  the public `asobi` library with a Lua `game.*` API via Luerl. Depends on
  `asobi` + `luerl`. Lua integration code belongs **here**, never in `asobi`.
- **asobi_engine** (private) - single-tenant hosted image; depends on BOTH
  `asobi` and `asobi_lua`. Multi-tenant / SaaS / provisioning concerns belong
  there, never here.

## Scope - what belongs here

- **In:** the Luerl bridge (loader, match, world, shared-state variants), the
  `game.*` API surface, hot-reload, the sandbox, script validation, and the
  bot runtime.
- **The `game.*` surface must stay generic across mobile and MMO games.** It is
  a general primitive set (economy, leaderboards, storage, messaging, chat,
  notifications, spatial, zones, terrain), not a feature dumping ground. Never
  warp it for one game (Barrow, Space Corsairs, etc.); a single-game need
  belongs in that game's Lua code.
- **Out:** anything that is really an `asobi` runtime primitive (push it DOWN
  into `asobi` so self-hosters and Erlang authors get it too), and anything
  multi-tenant / hosted (that is `asobi_engine`).
- Any architectural change, new `game.*` namespace, or API addition goes past
  the **asobi-architecture-guardian** agent first (it covers asobi + asobi_lua).

## Commands

```bash
rebar3 compile
rebar3 eunit                 # unit + proper property suites
docker compose up -d         # Postgres 17 for storage-backed tests
rebar3 ct                    # asobi_lua_SUITE
rebar3 fmt                   # erlfmt (write); CI runs fmt --check
rebar3 xref
rebar3 dialyzer
rebar3 ex_doc                # fix every warning before push
rebar3 shell                 # dev_sys.config
```

Migrations are never hand-written; the storage schema comes from `asobi`. Use
`rebar3 kura compile` if a migration is ever needed here.

## Pre-push checklist (all green)

`rebar3 fmt` -> `rebar3 xref` -> `rebar3 dialyzer` -> `rebar3 eunit` ->
`rebar3 ct` -> `rebar3 ex_doc` -> `rebar3 fmt --check`.

CI additionally runs dependency audit; eqwalize/lint/mutate not wired here
(eqwalize panics on OTP 29) - add if that changes.

## Conventions

- OTP 29.0.2 (`.tool-versions`); `warnings_as_errors` + `warn_missing_spec`.
- The `~"..."` sigil for binaries, never `<<"...">>`.
- No `lists:foldl/foldr` in new code - list comprehensions, `maps:from_list`,
  or explicit named recursion.
- Logging: `?LOG_*` macros with `#{...}` map reports, never `logger:info/error`
  format strings.
- JSON: OTP `json` module, never thoas/jiffy.
- Docs: OTP `-moduledoc` / `-doc`; guides under `guides/`, ADRs under
  `docs/adr/` (Nygard format) - read them before changing a bridge contract.
- `{vsn, git}` in `.app.src` - version derives from git tags, never edited.
- British English for all asobi-family content. Plain ASCII hyphen, no em
  dashes.

## Architecture

```
asobi_lua_app / asobi_lua_sup
  src/lua/
    asobi_lua_loader        Luerl state: load script, install sandbox + require
    asobi_lua_api           installs the game.* namespace into a Luerl state
    asobi_lua_match         asobi_match impl; delegates callbacks to Lua
    asobi_lua_world         asobi_world impl (large-world / zones / terrain)
    asobi_lua_match_shared  shared-state match variant
    asobi_lua_reload        hot-reload: swap the Luerl chunk, keep match state
    asobi_lua_validate      surfaces load errors / sandbox / traversal
  src/bots/
    asobi_bot(_sup/_spawner) gen_server bot runtime that fills matches
```

Each match/world runs as its own BEAM process under an `asobi` supervisor;
Luerl executes the Lua inside that process (no sub-process, no GC pauses). The
Lua author's callbacks (`init/join/handle_input/tick/...`) are delegated from
the Erlang match/world module. `asobi_lua_api:install/2` pre-creates the
`game.*` namespace tables and installs each function before the script's
`init()` runs.

## `game.*` API (grounded in `asobi_lua_api`)

`game.id()`, `game.broadcast/send`; `game.economy.{grant,debit,balance,
purchase}`; `game.leaderboard.{submit,top,rank,around}`; `game.notify` +
`game.notify_many`; `game.storage.{get,set,player_get,player_set}`;
`game.chat.send`; `game.spatial.{query_radius,query_rect,nearest,in_range,
distance}`; `game.zone.{spawn,despawn}` and `game.terrain.{get_chunk,preload}`
(world mode only, gated on `zone_pid` / `terrain_store_pid` in context).

## Luerl gotchas (baked into the bridge - respect them)

- **Lua numbers are floats.** `return 5` decodes to `5.0`; the bridge `trunc/1`s
  before calling integer-typed `asobi` functions. Do the same for any new call.
- **State is immutable and threaded.** Every Luerl op returns a new state; each
  `game.*` function is `fun(Args, St) -> {[Results], St1}` and must thread `St`.
- **Decode is defensive.** `deep_decode/1` turns Luerl proplists into native
  maps/lists and caps recursion at 64 levels (a hostile deep table can't OOM
  the match). Empty Lua tables round to `#{}`.
- **Sandbox.** The loader strips `os.execute/exit/getenv/remove/rename/tmpname`,
  the whole `io` and `package` libs, and `dofile/loadfile/load/loadstring`.
  `require/1` is an asobi_lua-controlled shim that resolves relative to the
  script dir and rejects `..` traversal. Never weaken this without an ADR.
- **Callbacks run under a wall-clock timeout** (`do_with_timeout`) so a runaway
  script can't wedge the match loop. Hot reload swaps the chunk while match
  state stays on the process heap.

## Tests

`rebar3 eunit` runs the `*_tests.erl` suites plus the `prop_*` PropEr suites
(sandbox, error containment, state round-trip, input threading/robustness).
`asobi_lua_SUITE` (CT) and storage-backed paths need the Docker Postgres from
`docker compose up -d`. Lua fixtures live in `test/fixtures/lua/`. Always add
or update tests alongside a bridge or `game.*` change.

## Git and PRs

Conventional commits (`feat:`, `fix:`, `chore:`, `docs:`, `test:`,
`refactor:`). Always branch and open a PR - never push to `main`. Every merge
to `main` tags a release, so keep each PR coherent. No `Co-Authored-By` trailer
and no "Generated with Claude Code" branding on any commit or PR. CI is
`Taure/erlang-ci` (pinned SHA, `otp-matrix` 29.0.2); nightly, docker-publish,
and the asobi-pin bump run as separate workflows.
