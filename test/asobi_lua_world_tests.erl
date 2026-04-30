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

%% --- Direct unit tests for individual world callbacks ---

init_invokes_init_callback_test() ->
    %% asobi_lua_world:init/1 must call the Lua init() and stash both
    %% lua_state and game_state. A regression that drops game_state
    %% would surface as join/leave hitting nil.
    {ok, State} = asobi_lua_world:init(#{lua_script => fixture("config_move_world.lua")}),
    ?assertMatch(#{lua_state := _, game_state := _}, State).

join_callback_threads_state_test() ->
    {ok, S0} = asobi_lua_world:init(#{lua_script => fixture("config_move_world.lua")}),
    {ok, S1} = asobi_lua_world:join(~"p1", S0),
    ?assert(is_map(S1)).

leave_callback_returns_ok_test() ->
    {ok, S0} = asobi_lua_world:init(#{lua_script => fixture("config_move_world.lua")}),
    ?assertMatch({ok, _}, asobi_lua_world:leave(~"p1", S0)).

spawn_position_decodes_xy_test() ->
    {ok, S0} = asobi_lua_world:init(#{lua_script => fixture("config_move_world.lua")}),
    {ok, {X, Y}} = asobi_lua_world:spawn_position(~"p1", S0),
    ?assert(is_number(X)),
    ?assert(is_number(Y)).

post_tick_returns_ok_test() ->
    {ok, S0} = asobi_lua_world:init(#{lua_script => fixture("config_move_world.lua")}),
    ?assertMatch({ok, _}, asobi_lua_world:post_tick(1, S0)).

get_state_returns_view_test() ->
    {ok, S0} = asobi_lua_world:init(#{lua_script => fixture("config_move_world.lua")}),
    View = asobi_lua_world:get_state(~"p1", S0),
    ?assert(is_map(View)).

phases_returns_empty_when_undefined_test() ->
    %% A script without a phases() function must return [], not crash.
    {ok, S0} = asobi_lua_world:init(#{lua_script => fixture("config_move_world.lua")}),
    ?assertEqual([], asobi_lua_world:phases(S0)).

spawn_templates_returns_empty_when_undefined_test() ->
    {ok, S0} = asobi_lua_world:init(#{lua_script => fixture("config_move_world.lua")}),
    ?assertEqual(#{}, asobi_lua_world:spawn_templates(S0)).

terrain_provider_returns_none_when_undefined_test() ->
    {ok, S0} = asobi_lua_world:init(#{lua_script => fixture("config_move_world.lua")}),
    ?assertEqual(none, asobi_lua_world:terrain_provider(S0)).

terrain_provider_decodes_module_test() ->
    Path = world_temp_script(
        ~"""
        match_size = 1
        max_players = 1
        game_type = "world"
        function init(_) return {} end
        function spawn_position(_, _) return { x = 0, y = 0 } end
        function generate_world(_, _) return { ['0,0'] = {} } end
        function zone_tick(e, z) return e, z end
        function handle_input(_, _, e) return e end
        function post_tick(_, s) return s end
        function terrain_provider(_)
            return { module = 'erlang', args = { foo = 'bar' } }
        end
        """
    ),
    %% H-2: terrain provider modules must be on the allowlist. Add
    %% `erlang` for this round-trip test only.
    Old = application:get_env(asobi_lua, terrain_providers),
    application:set_env(asobi_lua, terrain_providers, [erlang]),
    try
        {ok, S0} = asobi_lua_world:init(#{lua_script => Path}),
        ?assertMatch({erlang, #{}}, asobi_lua_world:terrain_provider(S0))
    after
        case Old of
            {ok, V} -> application:set_env(asobi_lua, terrain_providers, V);
            undefined -> application:unset_env(asobi_lua, terrain_providers)
        end,
        file:delete(Path)
    end.

terrain_provider_unknown_module_returns_none_test() ->
    %% A bogus module name must NOT create a new atom, and the bridge
    %% returns `none` rather than crashing.
    Path = world_temp_script(
        ~"""
        match_size = 1
        max_players = 1
        game_type = "world"
        function init(_) return {} end
        function spawn_position(_, _) return { x = 0, y = 0 } end
        function generate_world(_, _) return { ['0,0'] = {} } end
        function zone_tick(e, z) return e, z end
        function handle_input(_, _, e) return e end
        function post_tick(_, s) return s end
        function terrain_provider(_)
            return { module = 'definitely_not_a_real_module_xyz', args = {} }
        end
        """
    ),
    try
        {ok, S0} = asobi_lua_world:init(#{lua_script => Path}),
        ?assertEqual(none, asobi_lua_world:terrain_provider(S0))
    after
        file:delete(Path)
    end.

phases_returns_decoded_phases_test() ->
    Path = world_temp_script(
        ~"""
        match_size = 1
        max_players = 1
        game_type = "world"
        function init(_) return {} end
        function spawn_position(_, _) return { x = 0, y = 0 } end
        function generate_world(_, _) return { ['0,0'] = {} } end
        function zone_tick(e, z) return e, z end
        function handle_input(_, _, e) return e end
        function post_tick(_, s) return s end
        function phases(_)
            return {
                { name = 'lobby', duration = 5000 },
                { name = 'play',  duration = 30000, start = 'prev_ended' }
            }
        end
        """
    ),
    try
        {ok, S0} = asobi_lua_world:init(#{lua_script => Path}),
        Phases = asobi_lua_world:phases(S0),
        ?assertEqual(2, length(Phases)),
        [Lobby, Play] = Phases,
        ?assertEqual(~"lobby", maps:get(name, Lobby)),
        ?assertEqual(prev_ended, maps:get(start, Play))
    after
        file:delete(Path)
    end.

phases_non_list_returns_empty_test() ->
    %% When phases() returns garbage, the bridge logs and returns [].
    Path = world_temp_script(
        ~"""
        match_size = 1
        max_players = 1
        game_type = "world"
        function init(_) return {} end
        function spawn_position(_, _) return { x = 0, y = 0 } end
        function generate_world(_, _) return { ['0,0'] = {} } end
        function zone_tick(e, z) return e, z end
        function handle_input(_, _, e) return e end
        function post_tick(_, s) return s end
        function phases(_) return 42 end
        """
    ),
    try
        {ok, S0} = asobi_lua_world:init(#{lua_script => Path}),
        ?assertEqual([], asobi_lua_world:phases(S0))
    after
        file:delete(Path)
    end.

spawn_templates_decodes_test() ->
    Path = world_temp_script(
        ~"""
        match_size = 1
        max_players = 1
        game_type = "world"
        function init(_) return {} end
        function spawn_position(_, _) return { x = 0, y = 0 } end
        function generate_world(_, _) return { ['0,0'] = {} } end
        function zone_tick(e, z) return e, z end
        function handle_input(_, _, e) return e end
        function post_tick(_, s) return s end
        function spawn_templates(_)
            return {
                goblin = { type = 'npc', persistent = true, base_state = { hp = 10 } }
            }
        end
        """
    ),
    try
        {ok, S0} = asobi_lua_world:init(#{lua_script => Path}),
        Templates = asobi_lua_world:spawn_templates(S0),
        ?assertMatch(#{~"goblin" := _}, Templates),
        Goblin = maps:get(~"goblin", Templates),
        ?assertEqual(~"npc", maps:get(type, Goblin)),
        ?assertEqual(true, maps:get(persistent, Goblin))
    after
        file:delete(Path)
    end.

on_phase_started_threads_state_test() ->
    Path = world_temp_script(
        ~"""
        match_size = 1
        max_players = 1
        game_type = "world"
        function init(_) return { phase = nil } end
        function spawn_position(_, _) return { x = 0, y = 0 } end
        function generate_world(_, _) return { ['0,0'] = {} } end
        function zone_tick(e, z) return e, z end
        function handle_input(_, _, e) return e end
        function post_tick(_, s) return s end
        function on_phase_started(name, s) s.phase = name; return s end
        """
    ),
    try
        {ok, S0} = asobi_lua_world:init(#{lua_script => Path}),
        ?assertMatch({ok, _}, asobi_lua_world:on_phase_started(~"play", S0))
    after
        file:delete(Path)
    end.

on_phase_ended_threads_state_test() ->
    Path = world_temp_script(
        ~"""
        match_size = 1
        max_players = 1
        game_type = "world"
        function init(_) return {} end
        function spawn_position(_, _) return { x = 0, y = 0 } end
        function generate_world(_, _) return { ['0,0'] = {} } end
        function zone_tick(e, z) return e, z end
        function handle_input(_, _, e) return e end
        function post_tick(_, s) return s end
        function on_phase_ended(_, s) return s end
        """
    ),
    try
        {ok, S0} = asobi_lua_world:init(#{lua_script => Path}),
        ?assertMatch({ok, _}, asobi_lua_world:on_phase_ended(~"play", S0))
    after
        file:delete(Path)
    end.

on_zone_loaded_returns_zone_state_test() ->
    Path = world_temp_script(
        ~"""
        match_size = 1
        max_players = 1
        game_type = "world"
        function init(_) return {} end
        function spawn_position(_, _) return { x = 0, y = 0 } end
        function generate_world(_, _) return { ['0,0'] = {} } end
        function zone_tick(e, z) return e, z end
        function handle_input(_, _, e) return e end
        function post_tick(_, s) return s end
        function on_zone_loaded(cx, cy, s) return { cx = cx, cy = cy }, s end
        """
    ),
    try
        {ok, S0} = asobi_lua_world:init(#{lua_script => Path}),
        {ok, ZoneState, _S1} = asobi_lua_world:on_zone_loaded({3, 4}, S0),
        ?assertEqual(3, maps:get(~"cx", ZoneState)),
        ?assertEqual(4, maps:get(~"cy", ZoneState))
    after
        file:delete(Path)
    end.

on_zone_unloaded_returns_ok_test() ->
    Path = world_temp_script(
        ~"""
        match_size = 1
        max_players = 1
        game_type = "world"
        function init(_) return {} end
        function spawn_position(_, _) return { x = 0, y = 0 } end
        function generate_world(_, _) return { ['0,0'] = {} } end
        function zone_tick(e, z) return e, z end
        function handle_input(_, _, e) return e end
        function post_tick(_, s) return s end
        function on_zone_unloaded(_, _, s) return s end
        """
    ),
    try
        {ok, S0} = asobi_lua_world:init(#{lua_script => Path}),
        ?assertMatch({ok, _}, asobi_lua_world:on_zone_unloaded({1, 1}, S0))
    after
        file:delete(Path)
    end.

on_world_recovered_threads_state_test() ->
    Path = world_temp_script(
        ~"""
        match_size = 1
        max_players = 1
        game_type = "world"
        function init(_) return { recovered = false } end
        function spawn_position(_, _) return { x = 0, y = 0 } end
        function generate_world(_, _) return { ['0,0'] = {} } end
        function zone_tick(e, z) return e, z end
        function handle_input(_, _, e) return e end
        function post_tick(_, s) return s end
        function on_world_recovered(_, s) s.recovered = true; return s end
        """
    ),
    try
        {ok, S0} = asobi_lua_world:init(#{lua_script => Path}),
        ?assertMatch({ok, _}, asobi_lua_world:on_world_recovered(#{~"snap" => ~"data"}, S0))
    after
        file:delete(Path)
    end.

%% --- Helpers ---

-spec world_temp_script(binary()) -> file:filename_all().
world_temp_script(Code) ->
    Name = "world_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".lua",
    Path = filename:join([filename:basedir(user_cache, "asobi_lua_tests"), Name]),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, Code),
    Path.
