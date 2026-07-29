-module(asobi_lua_config_watcher_tests).

-include_lib("eunit/include/eunit.hrl").

watcher_test_() ->
    {foreach,
        fun() ->
            application:set_env(asobi, game_modes, #{}),
            application:set_env(asobi_lua, reload_mode, auto)
        end,
        fun(_) ->
            application:set_env(asobi, game_modes, #{}),
            application:unset_env(asobi_lua, reload_mode),
            application:unset_env(asobi, game_dir)
        end,
        [
            {"a changed match_size is reloaded on tick", fun reloads_on_change/0},
            {"reload_mode=off is a no-op", fun off_is_noop/0},
            {"unchanged mtimes do not reload", fun unchanged_is_noop/0}
        ]}.

%% match_size edited then a tick fires -> game_modes picks up the new value.
reloads_on_change() ->
    Dir = temp_dir(),
    Path = filename:join(Dir, "match.lua"),
    ok = file:write_file(Path, ~"match_size = 2\n"),
    application:set_env(asobi, game_dir, Dir),
    ok = asobi_lua_config:maybe_load_game_config(),
    ?assertEqual(2, match_size()),

    ok = file:write_file(Path, ~"match_size = 1\n"),
    tick(stale_mtimes()),
    ?assertEqual(1, match_size()).

%% With reload_mode=off the watcher must not reload even when files changed.
off_is_noop() ->
    Dir = temp_dir(),
    Path = filename:join(Dir, "match.lua"),
    ok = file:write_file(Path, ~"match_size = 2\n"),
    application:set_env(asobi, game_dir, Dir),
    ok = asobi_lua_config:maybe_load_game_config(),
    ?assertEqual(2, match_size()),

    ok = file:write_file(Path, ~"match_size = 1\n"),
    application:set_env(asobi_lua, reload_mode, off),
    tick(stale_mtimes()),
    ?assertEqual(2, match_size()).

%% When the scanned mtimes equal the stored snapshot, no reload happens.
unchanged_is_noop() ->
    Dir = temp_dir(),
    Path = filename:join(Dir, "match.lua"),
    ok = file:write_file(Path, ~"match_size = 2\n"),
    application:set_env(asobi, game_dir, Dir),
    ok = asobi_lua_config:maybe_load_game_config(),

    %% Change the file on disk but pass the CURRENT mtimes as the snapshot, so
    %% the watcher sees no delta and skips the reload.
    Current = current_mtimes(Dir, Path),
    ok = file:write_file(Path, ~"match_size = 9\n"),
    _ = file:change_time(Path, calendar:local_time()),
    {noreply, _} = asobi_lua_config_watcher:handle_info(
        tick, #{interval => 100000, mtimes => Current}
    ),
    ?assertEqual(2, match_size()).

%% --- helpers ---

tick(Mtimes) ->
    {noreply, _} = asobi_lua_config_watcher:handle_info(
        tick, #{interval => 100000, mtimes => Mtimes}
    ),
    ok.

%% A snapshot guaranteed to differ from any real scan, so a tick treats it as a
%% change and reloads (sidesteps 1s mtime granularity in the test).
stale_mtimes() ->
    #{"/nonexistent/stale/path" => 0}.

current_mtimes(Dir, Path) ->
    #{
        filename:join(Dir, "config.lua") => filelib:last_modified(filename:join(Dir, "config.lua")),
        Path => filelib:last_modified(Path)
    }.

match_size() ->
    Modes = application:get_env(asobi, game_modes, #{}),
    [Mode | _] = maps:values(Modes),
    maps:get(match_size, Mode).

temp_dir() ->
    Base = filename:join([
        "/tmp",
        "asobi_lua_watcher_test",
        integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = filelib:ensure_dir(filename:join(Base, "x")),
    Base.
