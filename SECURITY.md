# Security Policy

## Reporting a vulnerability

If you discover a security vulnerability in `asobi_lua`, please report it
**privately** so we can fix it before it is publicly disclosed.

**Do not open a public GitHub issue for security issues.**

### How to report

Either of these channels work:

- **GitHub Security Advisory (preferred):**
  [Report privately](https://github.com/widgrensit/asobi_lua/security/advisories/new)
- **Email:** security@asobi.dev

### What to expect

- Acknowledgement within **48 hours**
- Initial assessment within **7 days**
- Coordinated disclosure timeline agreed with you
- Credit in the security advisory if you want it

## Supported versions

| Version | Supported |
|---------|-----------|
| latest stable | ✅ |
| older releases | ❌ — please upgrade |

## Scope

**In scope:**
- The `asobi_lua` Erlang/OTP runtime (this repository)
- The Luerl sandbox configuration shipped with this runtime

**Out of scope:**
- The hosted asobi.dev SaaS — see https://asobi.dev/security
- The `asobi` library — report to https://github.com/widgrensit/asobi/security
- Third-party dependencies (Luerl etc.) — please report upstream

## Sandbox model

asobi_lua runs every Lua script in a hardened Luerl state. Sandbox
construction lives in `asobi_lua_loader:new/1` and
`asobi_lua_loader:init_sandboxed/0`.

### Removed from the global environment

The following standard-library entries are cleared (`= nil`) so a hostile
script cannot reach them:

- **OS escape hatches:** `os.execute`, `os.exit`, `os.getenv`,
  `os.remove`, `os.rename`, `os.tmpname`
- **Code loading:** `dofile`, `loadfile`, `load`, `loadstring`
- **I/O:** the entire `io` library
- **Package machinery:** the entire `package` library, plus the default
  `require`

`os.clock`, `os.date`, `os.difftime`, and `os.time` remain available so
games can timestamp.

### Replaced

- **`require/1`** is provided by asobi_lua. Names must match
  `[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*` — letters, digits,
  underscores, with `.` separating segments. Names like `../foo`,
  `/etc/passwd`, `foo/bar`, `42`, or `''` are rejected. The resolver
  joins the validated name to the directory of the script that was
  loaded (e.g. `require("bots.chaser")` →
  `<base>/bots/chaser.lua`) and reads the file with `file:read_file/1`.
  Module results are cached in the Luerl state's private
  `_ASOBI_LOADED` table; `asobi_lua_match` clears that cache on
  hot-reload so changed modules pick up.
- **`math.random`** dispatches to Erlang's `rand:uniform`. Single-arg
  form returns an integer in `[1, N]`; no-arg form returns a float in
  `[0, 1)`. The two-arg `math.random(a, b)` form upstream Lua exposes
  is **not** supported.
- **`math.sqrt`** dispatches to Erlang's `math:sqrt/1`. Negative input
  returns `0.0` (upstream Lua returns NaN; Erlang would crash).

### Per-callback wall-clock limits

Every Lua callback the bridges call (init, tick, join, leave,
handle_input, get_state, vote_requested, vote_resolved, generate_world,
phases, spawn_templates, on_phase_started/ended, on_zone_loaded/unloaded,
on_world_recovered, terrain_provider, spawn_position, post_tick,
zone_tick, bot `think`) runs in a child process with a wall-clock budget.
A runaway script (`while true do end`, deep recursion, huge allocation)
is killed when its budget elapses; the parent gen_server logs a warning
and continues with the previous state. Limits are tuned per callback —
init/generate_world get more time, per-tick callbacks get less. See
the `?*_TIMEOUT` macros in `asobi_lua_match.erl` and `asobi_lua_world.erl`.

### Cross-script isolation

Each match and each zone gets its own Luerl state. Globals, modules,
and the require cache live inside that state — there is no shared
table reachable from script code that crosses match boundaries.

### Atom exhaustion

`asobi_lua_api:safe_to_atom/1` and `terrain_provider` decoding both
use `binary_to_existing_atom/1` so a Lua-supplied string cannot
inflate the global atom table. There is a regression test in
`asobi_lua_sandbox_tests` that fails if the limit is widened.

### What is NOT enforced

- **Reduction limit / hard CPU cap.** The wall-clock timeout is the
  only resource bound today. A script can soak its full budget every
  tick without being throttled.
- **Heap cap per script.** Lua tables grow inside the BEAM process
  heap. A pathological script that allocates 100 MB of tables and
  drops them every tick will pressure the OS memory allocator.
- **Read-only filesystem.** The Docker image runs as the non-root
  `asobi` user but does not declare `--read-only`. The README example
  mounts `/app/game` `:ro`; that mode is the **operator's**
  responsibility, not the runtime's.

### Trust model

asobi_lua treats the mounted `/app/game` Lua scripts as **trusted**
in the same sense your `/app/bin/asobi_lua` binary is trusted: you
control what files end up there. The sandbox protects against
incidental scripting bugs (infinite loops, missed nil checks, atom
exhaustion via untrusted player input) and makes it harder for a
*compromised* dependency or `require`'d module to escape. It is not
a defence against a deliberate, all-Erlang-aware adversary with the
ability to write `/app/game/match.lua`.
