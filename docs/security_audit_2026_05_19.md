# asobi_lua security audit - 2026-05-19

Latest commit audited: `2bce7b6 chore(deps): bump asobi pin (kura v2.0.4 + storage unique-index fix)`.
Scope: every module under `src/`, the runtime sandbox, the bot subsystem, the
config loader, the Lua-facing `game.*` API, the rebar/CI config, and repo
hygiene. Out of scope: the upstream `asobi` library (its own security advisory
channel) and the Luerl interpreter itself.

## Summary

Totals: 0 Critical / 1 High / 3 Medium / 4 Low / 4 Informational

Top-line: the runtime does **not** call `luerl_sandbox:init/1`. It instead
builds its own hardened state in `asobi_lua_loader:sandboxed_state/1`. After
walking the resulting allow/deny set the sandbox is broadly equivalent to
`luerl_sandbox` and in some respects stricter (`print`/`eprint` cleared, custom
`require` with traversal-resistant resolver, math overrides). One gap exists
vs. `luerl_sandbox` (`file` library not cleared, though it is empty in
upstream Luerl 1.5.x today). The main outstanding risks are deeper:
filesystem-path joins on Lua-controlled config strings without normalisation,
unbounded reductions/heap on the hot `handle_input` path, and a `debug.*`
sub-library that is still reachable.

## High

### H1 - `config.lua` and match-script `bots.script` paths bypass game-dir containment

`asobi_lua_config:build_modes_from_manifest/2` line 102 and
`asobi_lua_config:maybe_add_bots/3` line 271 both do
`filename:join(BaseDir, binary_to_list(<from-lua>))` with no `..`
normalisation, then `asobi_lua_loader:new/1` (`file:read_file` line 82,
`src/lua/asobi_lua_loader.erl`) reads and **executes** the result as Lua. A
malicious `config.lua` (or `match.lua` `bots = { script = "../../whatever.lua" }`)
can therefore load and run any `.lua`-or-not file the runtime user can read,
anywhere on the filesystem. Once loaded the file body runs under the sandbox,
so it cannot reach OS syscalls — but it can mutate world state, drain economy,
and (most importantly) **read file contents into a script-controlled global**
where the script can then leak them via `game.broadcast`/`game.storage.set`.

This is also the entry point for amplifying L2 (mtime self-DoS) into a
cross-tenant problem on multi-game deployments.

The require-resolver (`asobi_lua_loader:validate_module_name/1` line 297)
**does** block this for in-script `require(...)` calls (regex restricts to
`[A-Za-z_][A-Za-z0-9_]*` segments). The config-side paths skipped that
validator.

Fix: validate the Lua-supplied path with the same identifier regex (or a
slash-allowing variant for `arena/match.lua`), reject any segment equal to
`..`, normalise via `filename:absname/1`, then assert
`lists:prefix(GameDir, NormPath)` before reading. Apply at both call sites.

## Medium

### M1 - No reduction limit or per-state heap cap on `handle_input/3`

ADR 0002 (`docs/adr/0002-skip-bounded-eval-for-handle-input.md`) intentionally
removed the spawn-and-kill wrapper from
`asobi_lua_match:handle_input/3` (line 132,
`src/lua/asobi_lua_match.erl`) and `asobi_lua_world:handle_input/3` (line 190,
`src/lua/asobi_lua_world.erl`) for a 35-45 % tail-latency win at 200 px × 10 Hz.
That trade is documented but only enforced upstream by the asobi gen_server's
`gen_server:call` timeout (5 s) — until then a `while true do end` inside
`handle_input` consumes a full scheduler with no Luerl reduction throttle. At
high input fan-in (player floods the channel) a single bad script can monopolise
an entire BEAM scheduler.

Luerl 1.5 exposes `luerl_sandbox:run/3` with `max_reductions` (see
`_build/default/lib/luerl/src/luerl_sandbox.erl` line 217). A defence-in-depth
mitigation is to add a *soft* reduction cap on `call_function` even on the
direct path. Re-measure the per-input overhead before committing.

### M2 - `debug.getmetatable` and `debug.setmetatable` are still reachable

`asobi_lua_loader:strip_dangerous_globals/1` (line 211 onwards,
`src/lua/asobi_lua_loader.erl`) clears `os.{execute,exit,getenv,remove,
rename,tmpname}`, `io`, `package`, `require`, `dofile`, `loadfile`, `load`,
`loadstring`, `print`, `eprint`. It does **not** clear `debug`.

`luerl_lib_debug` (in the bundled Luerl,
`_build/default/lib/luerl/src/luerl_lib_debug.erl` line 39-43) installs
`debug.getmetatable` and `debug.setmetatable`. These bypass the normal
`__metatable` field protection: a hostile script can call
`debug.setmetatable(_G, {__index = ...})` to install an `__index` handler on
the global table, intercepting future global reads from cooperating callbacks.
This does **not** restore the stripped function references (those are erased,
per the verified-negative note in `guides/security-trust-model.md`) so the
practical impact is limited to confusing already-trusted scripts and to
extending what a partially-compromised dependency can do.

`luerl_sandbox:init/0` does **not** clear `debug` either, so this is not a
regression relative to using the upstream sandbox. But the upstream's own
hardening is the floor, not the ceiling; the project should set it.

Fix: add `[~"debug"]` to the `Paths` list in `strip_dangerous_globals/1`.
Update `guides/security-sandbox.md` accordingly.

### M3 - `do_with_timeout_results/3` in `asobi_lua_config` skips the heap cap

`asobi_lua_config:do_with_timeout_results/3` (line 315,
`src/asobi_lua_config.erl`) is the timeout wrapper used to evaluate
`config.lua`. It uses a plain `spawn/1` with no `max_heap_size`, unlike
`asobi_lua_loader:bounded_eval/2` (line 153, `src/lua/asobi_lua_loader.erl`)
which uses `spawn_opt` with `max_heap_size: kill => true`. A `config.lua` with
an allocation bomb at module top-level will inflate the BEAM heap until
`?CONFIG_TIMEOUT_MS` (2000 ms) expires. Two seconds at modern allocation
rates is millions of words.

Fix: reuse `asobi_lua_loader:bounded_eval/2` (export it / inline the
`spawn_opt` flags) so the manifest evaluator gets the same heap cap.

## Low

### L1 - Hot-reload re-execution carries forward script-controlled globals

`asobi_lua_reload:reload_script/2` (line 121, `src/lua/asobi_lua_reload.erl`)
clears the `_ASOBI_LOADED` require cache (good) and then re-executes the new
file body **against the same Luerl state**, by design (the doc-string at
lines 11-15 explains why: preserving in-flight game state). A previous tick's
script that set `_G.ASOBI_PATCHED = true` then triggered the reload could leave
that global in place to influence the new code. This is documented behaviour
and assumes a trusted operator wrote both versions; flag it explicitly in the
sandbox guide.

### L2 - mtime poll on every tick + symlink behaviour

`asobi_lua_reload:do_maybe_reload/1` (line 73) `stat()`s the script file on
**every** match tick and **every** zone tick. A symlinked game dir whose
target's mtime is touched by a noisy CI/CD will reload on every tick (no
debounce). Symlink rejection lives only in `require` path (line 337,
`asobi_lua_loader.erl`) — the top-level script path passed to `new/1` can
itself be a symlink. Not exploitable in the documented threat model (the
operator owns the mount) but contributes to L1 if combined with a writable
mount.

Fix (optional): debounce reloads to once per N ms and/or add the symlink check
to the top-level `read_file` path in `asobi_lua_loader:new/3`.

### L3 - `cowlib 2.16.1` advisory (LOW)

`rebar3 audit` reports 1 vulnerability across 22 deps; the only flagged
package is `cowlib` 2.16.1 (LOW severity, pulled in transitively via
`cowboy 2.13.0`). Audit summary is gated by an unrelated rebar3_audit
printing bug that prevents the full GHSA ID from displaying — fix that plugin
or look up the cowlib advisory directly to confirm impact (likely the
known HTTP/2 header parsing DoS that was already patched in cowlib 2.17+).
Bump `cowboy`/`cowlib` once an asobi upstream release pins newer versions.

### L4 - `safe_to_atom/1` falls through to the binary on `binary_to_existing_atom` failure

`asobi_lua_api:safe_to_atom/1` (line 863, `src/lua/asobi_lua_api.erl`)
returns the original binary on failure, which then flows into
`asobi_spatial:in_range/3` etc. as a map key. The downstream consumer
(`asobi_spatial`) is expected to handle non-atom keys gracefully, but the
contract is implicit — a future refactor that adds `is_atom(K)` filtering on
the asobi side would silently drop script-supplied entity keys. Add a
documenting test + spec, or hard-fail at the bridge boundary so the contract
is enforced.

## Informational

### I1 - `erl_crash.dump` exists in working tree (not tracked)

`/home/dnwid/ai/work/asobi_lua/erl_crash.dump` (1.8 MB, dated 2026-04-30) is
gitignored (`/home/dnwid/ai/work/asobi_lua/.gitignore` line 4) so it cannot
leak via push. Inspecting it shows it captures a routine boot-arith failure
with no secrets. Safe to delete locally.

### I2 - `SECURITY.md` is complete and reviewer-friendly

`SECURITY.md` lines 1-57 cover reporting, supported versions, scope, and
references to the three security guides under `guides/`. The trust-model guide
even tracks "verified negative results" so future auditors don't re-derive
them. Good practice.

### I3 - `LICENSE` is Apache-2.0; CI uses pinned-SHA reusable workflows; Dependabot covers Actions + Docker; secret scanning enabled via GitHub repo defaults (assumed; verify in repo settings)

`.github/workflows/ci.yml` line 11 pins `Taure/erlang-ci` to a 40-char SHA
with a dated comment — exemplary supply-chain hygiene. `.github/dependabot.yml`
covers GH Actions weekly and Docker weekly. Add a third ecosystem entry for
`mix` if any Mix dep ever lands; for pure Erlang projects `rebar3` deps are
already covered by the `rebar3 audit` CI flag.

### I4 - Sandbox docs are unusually thorough

`guides/security-sandbox.md`, `guides/security-trust-model.md`, and
`guides/security-known-limitations.md` together form a coherent threat model.
Verified-negative entries in trust-model (lines 13-50) are particularly
valuable for downstream auditors. Update with the M2 fix and the H1 fix
once shipped.

## Already strong

- **Sandbox parity with `luerl_sandbox`**: same set of OS/IO/code-loading
  globals cleared (`asobi_lua_loader:strip_dangerous_globals/1` line 224 vs.
  `luerl_sandbox:?SANDBOXED_GLOBALS` line 48,
  `_build/default/lib/luerl/src/luerl_sandbox.erl`), plus
  extra `print`/`eprint` strip.
- **Custom `require` resolver** with regex validator
  (`asobi_lua_loader:validate_module_name/1` line 297) + symlink rejection
  (line 337) + per-state cache + cleared cache on hot-reload.
- **Per-callback wall-clock timeouts** + `max_heap_size: kill => true` on
  every wrapped callback (`asobi_lua_loader:bounded_eval/2` lines 153-192).
  Documented matrix in `guides/security-trust-model.md` lines 60-69.
- **Atom-table protection**: `binary_to_existing_atom/1` on the only two
  bridge paths that take Lua strings to atoms
  (`asobi_lua_api:safe_to_atom/1` line 865;
  `asobi_lua_world:lookup_allowed_provider/1` line 450). Allowlist for
  terrain-provider module dispatch (`asobi_lua_world` lines 401-456).
- **Decode-depth cap** at 64 levels prevents deep-table parent OOM
  (`asobi_lua_api:deep_decode/2` line 712).
- **Cross-match isolation** by giving each match/zone its own Luerl state.
  Verified by `asobi_lua_sandbox_tests:two_states_do_not_share_globals_test`.
- **No `os:cmd`, `binary_to_atom/1`, `binary_to_term/1`, `file:consult/1`,
  or `erlang:apply/3` on Lua-derived input** anywhere in `src/`.
- **Negative-test suite is real** (`asobi_lua_sandbox_tests` 230 LOC of
  must-not-pass assertions). Atom-stability regression test is parameterised
  on a runtime-built string so it would catch a `binary_to_atom/1` reversion.
- **Resource-limit suite** (`asobi_lua_resource_limits_tests.erl`) pins both
  the wrapped callbacks' timeout contract AND the deliberate exception for
  `handle_input` per ADR 0002.
- **Dockerfile runs as non-root `asobi` user**, mounts game dir under
  `/app/game`, uses `tini`. Known operator-side hardening
  (`--read-only`, `--tmpfs /tmp`) is called out in
  `guides/security-known-limitations.md` lines 36-43.

## How to apply

1. **H1**: validate + normalise the `config.lua` mode→script-path mapping and
   the `bots.script` path in `asobi_lua_config.erl` lines 102 and 271. Reject
   any path that escapes `GameDir`. Add tests in
   `test/asobi_lua_config_tests.erl` for `..` traversal, absolute paths, and
   symlink-pointing-out-of-tree.
2. **M3**: switch `do_with_timeout_results/3` to use `spawn_opt` with the same
   `max_heap_size` flags as `asobi_lua_loader:bounded_eval/2`. Export
   `bounded_eval/2` and reuse, or factor out the spawn-opts helper.
3. **M2**: add `[~"debug"]` to `strip_dangerous_globals/1` Paths list. Add a
   regression test in `asobi_lua_sandbox_tests` that asserts
   `debug` evaluates to `nil`.
4. **M1**: prototype a Luerl reduction cap on the `handle_input` path; benchmark
   against ADR 0002's numbers. Only enable if overhead is well under the
   ADR's 35-45 % saved-latency budget. Document in ADR 0002.
5. **L3**: when an asobi upstream release ships a cowboy/cowlib bump, rerun
   `rebar3 audit` and confirm the green-circle vulnerability has cleared.
6. **L1/L2**: update `guides/security-known-limitations.md` with explicit notes
   on global-carry-over across reload and top-level script symlinking.
7. **I3**: confirm secret scanning is enabled at the repo level in GitHub
   settings (organisation-wide default usually does this, but verify).
