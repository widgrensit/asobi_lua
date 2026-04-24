-module(asobi_lua_world_tests).
-include_lib("eunit/include/eunit.hrl").

-spec fixture(string()) -> file:filename_all().
fixture(Name) ->
    {ok, LibDir} = safe_lib_dir(),
    filename:absname(
        filename:join([LibDir, "test", "fixtures", "lua", Name])
    ).

-spec safe_lib_dir() -> {ok, string()}.
safe_lib_dir() ->
    case code:lib_dir(asobi_lua) of
        {error, bad_name} -> error(asobi_lua_not_loaded);
        Dir -> {ok, Dir}
    end.

generate_world_from_raw_config_test() ->
    %% asobi_world_server invokes generate_world/2 with the raw world config
    %% (no lua_state threaded through). The bridge must handle that by creating
    %% its own Lua state from game_config.lua_script.
    Config = #{
        mode => ~"test",
        game_config => #{lua_script => fixture("config_game_type_world.lua")}
    },
    {ok, ZoneStates} = asobi_lua_world:generate_world(0, Config),
    ?assert(is_map(ZoneStates)),
    %% The fixture declares one zone at "0,0"; the bridge parses it into a tuple.
    ?assert(maps:is_key({0, 0}, ZoneStates)),
    %% Each zone must have its own lua_state stitched in so zone_tick/
    %% handle_input can invoke Lua callbacks.
    Zone = maps:get({0, 0}, ZoneStates),
    ?assert(is_map(Zone)),
    ?assert(maps:is_key(lua_state, Zone)).

generate_world_missing_script_returns_empty_test() ->
    Config = #{game_config => #{}},
    ?assertEqual({ok, #{}}, asobi_lua_world:generate_world(0, Config)).

generate_world_bad_script_returns_empty_test() ->
    Config = #{game_config => #{lua_script => "/nonexistent/path.lua"}},
    ?assertEqual({ok, #{}}, asobi_lua_world:generate_world(0, Config)).
