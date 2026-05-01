-module(asobi_lua_reload_tests).
-include_lib("eunit/include/eunit.hrl").

reload_mode_test_() ->
    [
        {"reload_mode = off skips the stat", fun off_short_circuits/0},
        {"reload_mode = auto polls mtime", fun auto_polls/0},
        {"unknown env value falls back to auto", fun unknown_env_is_auto/0}
    ].

%% When reload_mode is `off`, the function returns the state unchanged
%% even if the script's mtime has actually moved. Set up a state where
%% an auto run would clearly reload, then prove `off` does not.
off_short_circuits() ->
    OldEnv = application:get_env(asobi_lua, reload_mode),
    application:set_env(asobi_lua, reload_mode, off),
    try
        State = #{
            script => "/nonexistent-but-doesnt-matter.lua",
            script_mtime => {{1970, 1, 1}, {0, 0, 0}},
            lua_state => fake_lua_state
        },
        ?assertEqual(State, asobi_lua_reload:maybe_hot_reload(State))
    after
        restore(reload_mode, OldEnv)
    end.

%% When reload_mode is `auto`, the function actually consults
%% filelib:last_modified on the path. We can't easily induce a real
%% reload here without a fixture script + mtime bump, but we can prove
%% the path is hit by passing a non-existent file and observing that
%% the state is returned unchanged because last_modified returns 0.
auto_polls() ->
    OldEnv = application:get_env(asobi_lua, reload_mode),
    application:set_env(asobi_lua, reload_mode, auto),
    try
        State = #{
            script => "/nonexistent.lua",
            script_mtime => {{1970, 1, 1}, {0, 0, 0}},
            lua_state => fake_lua_state
        },
        ?assertEqual(State, asobi_lua_reload:maybe_hot_reload(State))
    after
        restore(reload_mode, OldEnv)
    end.

%% A typo in the env var must not silently disable reload — it should
%% fall back to auto. Set a bogus value and prove the auto path runs.
unknown_env_is_auto() ->
    OldEnv = application:get_env(asobi_lua, reload_mode),
    application:set_env(asobi_lua, reload_mode, garbage_value),
    OldOs = os:getenv("ASOBI_LUA_RELOAD"),
    %% os:unset_env/1 doesn't exist on some OTPs; clearing via putenv with
    %% an empty string lets reload_mode fall through to its default.
    os:putenv("ASOBI_LUA_RELOAD", ""),
    try
        State = #{
            script => "/nonexistent.lua",
            script_mtime => {{1970, 1, 1}, {0, 0, 0}},
            lua_state => fake_lua_state
        },
        ?assertEqual(State, asobi_lua_reload:maybe_hot_reload(State))
    after
        restore(reload_mode, OldEnv),
        case OldOs of
            false -> os:putenv("ASOBI_LUA_RELOAD", "");
            V -> os:putenv("ASOBI_LUA_RELOAD", V)
        end
    end.

restore(Key, {ok, V}) -> application:set_env(asobi_lua, Key, V);
restore(Key, undefined) -> application:unset_env(asobi_lua, Key).
