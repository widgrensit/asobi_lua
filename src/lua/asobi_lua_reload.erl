-module(asobi_lua_reload).
-moduledoc """
Shared hot-reload primitive for Lua-backed match and world states.

Both `asobi_lua_match` and `asobi_lua_world` (per-world and per-zone) keep a
Luerl state alongside the path of the script that produced it. On every tick
we stat the file; if its mtime has moved, we re-execute the script body
against the current Luerl state — re-declaring globals and functions in
place — preserving in-flight game state.

Behaviour:
- Lua-side state (players, counters, tables) lives inside the Luerl state and
  survives reload, because the script body only reassigns globals and
  redefines functions; existing locals and table fields are not touched
  unless the script explicitly re-runs `init()`.
- Erlang-side state (the wrapper map) is untouched.
- A syntax error in the new script logs a warning, remembers the new mtime
  (so we don't keep retrying the same broken file), and keeps running the
  old code until the file is fixed.
- The `_ASOBI_LOADED` require cache is cleared so transitive `require()`d
  modules also re-read from disk.

## Deployment-mode notes

This is a **filesystem-mtime** primitive. It assumes the script lives at a
path the BEAM can `stat()`, and that "the script has changed" can be
expressed as a new mtime. Two real-world deployment models fit that:

- **Local dev** — Lua files mounted via a Docker bind mount or sitting under
  `/app/game/` directly. Edit-save triggers a reload on the next tick.
- **Self-hosted prod with a host-volume mount** — operator's CI/CD writes
  new files into the mounted directory (best practice: write to a temp file
  and `mv` for atomic swap). The next tick picks them up.

Two deployment models do NOT use this primitive at runtime, by design:

- **Sealed-bundle prod** (e.g. asobi managed cloud) — the bundle is
  extracted once at boot to an immutable directory; mtime never changes
  within a container's lifetime. New deploys are container restarts on a
  new generation. The per-tick `stat()` is a no-op in this model.
- **Custom script sources** (DB, S3, git, etc.) — these belong behind the
  planned `asobi_lua_source` behaviour, which will dispatch to either this
  filesystem implementation or an alternative loader. Until then, custom
  sources should arrange for files to land on disk and use this primitive,
  or implement reload outside it.

Operators running self-hosted with high zone counts who want to suppress
per-tick stat overhead should track the planned `ASOBI_LUA_RELOAD` config
(future): `auto` (default, mtime-poll), `signal` (only on explicit reload
RPC), `off` (immutable; require restart for code changes).
""".

-export([maybe_hot_reload/1]).

%% Reload runs script-author code under a wall-clock budget. A `while true do
%% end` in the file body would otherwise hang the calling gen_server forever
%% the moment its mtime ticked.
-define(RELOAD_TIMEOUT_MS, 5000).

-spec maybe_hot_reload(map()) -> map().
maybe_hot_reload(#{script := Path, script_mtime := OldMtime, lua_state := LuaSt} = State) ->
    case filelib:last_modified(Path) of
        0 ->
            State;
        OldMtime ->
            State;
        NewMtime ->
            case reload_script(Path, LuaSt) of
                {ok, NewLuaSt} ->
                    logger:notice(#{
                        msg => ~"lua hot reload", script => Path, mtime => NewMtime
                    }),
                    State#{lua_state => NewLuaSt, script_mtime => NewMtime};
                {error, Reason} ->
                    logger:warning(#{
                        msg => ~"lua hot reload failed",
                        script => Path,
                        reason => Reason
                    }),
                    State#{script_mtime => NewMtime}
            end
    end;
maybe_hot_reload(State) ->
    %% Legacy state from before hot-reload shipped — nothing to compare.
    State.

-spec reload_script(file:filename_all(), dynamic()) -> {ok, dynamic()} | {error, term()}.
reload_script(Path, LuaSt) ->
    case file:read_file(Path) of
        {ok, Code} ->
            CleanLuaSt = clear_require_cache(LuaSt),
            asobi_lua_loader:do_with_timeout(Code, CleanLuaSt, ?RELOAD_TIMEOUT_MS);
        {error, FileReason} ->
            {error, {file_error, FileReason}}
    end.

-spec clear_require_cache(dynamic()) -> dynamic().
clear_require_cache(LuaSt) ->
    {Empty, LuaSt1} = luerl:encode(#{}, LuaSt),
    {ok, LuaSt2} = luerl:set_table_keys([~"_ASOBI_LOADED"], Empty, LuaSt1),
    LuaSt2.
