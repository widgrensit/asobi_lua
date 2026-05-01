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
