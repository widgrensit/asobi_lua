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

handle_input_uses_zone_state_from_proc_dict_test() ->
    %% asobi_zone passes just the entities map to handle_input/3 (no lua_state).
    %% The bridge must recover lua_state from the zone's proc dict, which
    %% zone_tick populates. Verify the full flow end-to-end.
    Script = fixture("config_move_world.lua"),
    Config = #{game_config => #{lua_script => Script}},
    {ok, ZoneStates} = asobi_lua_world:generate_world(0, Config),
    ?assert(maps:is_key({0, 0}, ZoneStates)),
    ZoneState = maps:get({0, 0}, ZoneStates),

    %% First zone_tick primes the proc dict.
    erlang:erase({asobi_lua_world, zone_state}),
    {_Ents, ZoneState1} = asobi_lua_world:zone_tick(#{}, ZoneState),
    ?assertMatch(#{lua_state := _}, erlang:get({asobi_lua_world, zone_state})),

    %% A move input should invoke Lua's handle_input and return updated entities.
    Input = #{~"kind" => ~"move", ~"x" => 42, ~"y" => 7},
    {ok, Entities1} = asobi_lua_world:handle_input(~"p1", Input, #{}),
    ?assertMatch(#{~"p1" := #{~"x" := 42, ~"y" := 7}}, Entities1),

    %% Follow-up tick sees the handle_input lua_state changes (no crash).
    {_, _ZoneState2} = asobi_lua_world:zone_tick(Entities1, ZoneState1),
    erlang:erase({asobi_lua_world, zone_state}).

handle_input_without_stash_is_noop_test() ->
    erlang:erase({asobi_lua_world, zone_state}),
    ?assertEqual(
        {ok, #{a => 1}},
        asobi_lua_world:handle_input(~"p1", #{~"kind" => ~"move"}, #{a => 1})
    ).
