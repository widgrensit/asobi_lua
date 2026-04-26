-module(asobi_lua_config_tests).
-include_lib("eunit/include/eunit.hrl").

-spec fixture(string()) -> file:filename_all().
fixture(Name) ->
    {ok, LibDir} = safe_lib_dir(),
    filename:absname(
        filename:join([LibDir, "test", "fixtures", "lua", Name])
    ).

-spec fixture_dir() -> file:filename_all().
fixture_dir() ->
    {ok, LibDir} = safe_lib_dir(),
    filename:absname(
        filename:join([LibDir, "test", "fixtures", "lua"])
    ).

-spec safe_lib_dir() -> {ok, string()}.
safe_lib_dir() ->
    case code:lib_dir(asobi_lua) of
        {error, bad_name} -> error(asobi_lua_not_loaded);
        Dir -> {ok, Dir}
    end.

%% --- Tests ---

config_test_() ->
    {foreach, fun() -> application:set_env(asobi, game_modes, #{}) end,
        fun(_) -> application:set_env(asobi, game_modes, #{}) end, [
            {"single mode: loads match.lua globals", fun single_mode_loads_globals/0},
            {"single mode: minimal config (only match_size)", fun single_mode_minimal/0},
            {"single mode: missing match_size fails", fun single_mode_missing_size/0},
            {"multi mode: loads config.lua manifest", fun multi_mode_manifest/0},
            {"no config files: no-op", fun no_config_noop/0},
            {"bot names: reads from bot script", fun bot_names_from_script/0},
            {"bot names: falls back to defaults", fun bot_names_fallback/0},
            {"world config: reads zone settings", fun world_config_zone_settings/0},
            {"world config: reads phase 2 settings", fun world_config_phase2_settings/0},
            {"game_type world selects world bridge", fun game_type_world_selects_world_bridge/0},
            {"game_type absent defaults to match bridge", fun game_type_absent_defaults_to_match/0},
            {"empty_grace_ms global is forwarded to mode config", fun empty_grace_ms_forwarded/0}
        ]}.

single_mode_loads_globals() ->
    application:set_env(asobi, game_dir, fixture_dir()),
    ok = asobi_lua_config:maybe_load_game_config(),
    Modes = get_game_modes(),
    ?assert(is_map_key(~"default", Modes)),
    Mode = maps:get(~"default", Modes),
    ?assertMatch(#{module := {lua, _}, match_size := 4, max_players := 10, strategy := fill}, Mode),
    #{bots := #{enabled := true, script := BotScript}} = Mode,
    ?assert(is_binary(BotScript)).

single_mode_minimal() ->
    TmpDir = make_temp_dir(),
    {ok, Content} = file:read_file(fixture("config_minimal.lua")),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), Content),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Modes = get_game_modes(),
    Mode = maps:get(~"default", Modes),
    ?assertEqual(2, maps:get(match_size, Mode)),
    ?assertEqual(2, maps:get(max_players, Mode)),
    cleanup_temp_dir(TmpDir).

single_mode_missing_size() ->
    TmpDir = make_temp_dir(),
    {ok, Content} = file:read_file(fixture("config_no_size.lua")),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), Content),
    application:set_env(asobi, game_dir, TmpDir),
    {error, _} = asobi_lua_config:maybe_load_game_config(),
    cleanup_temp_dir(TmpDir).

multi_mode_manifest() ->
    TmpDir = make_temp_dir(),
    {ok, Manifest} = file:read_file(fixture("config_manifest.lua")),
    ok = file:write_file(filename:join(TmpDir, "config.lua"), Manifest),
    {ok, Match} = file:read_file(fixture("config_match.lua")),
    ok = file:write_file(filename:join(TmpDir, "config_match.lua"), Match),
    {ok, Minimal} = file:read_file(fixture("config_minimal.lua")),
    ok = file:write_file(filename:join(TmpDir, "config_minimal.lua"), Minimal),
    {ok, Boons} = file:read_file(fixture("boons.lua")),
    ok = file:write_file(filename:join(TmpDir, "boons.lua"), Boons),
    ok = file:make_dir(filename:join(TmpDir, "bots")),
    {ok, Chaser} = file:read_file(fixture("bots/chaser.lua")),
    ok = file:write_file(filename:join(TmpDir, "bots/chaser.lua"), Chaser),

    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Modes = get_game_modes(),
    ?assert(is_map_key(~"arena", Modes)),
    ?assert(is_map_key(~"minimal", Modes)),
    Arena = maps:get(~"arena", Modes),
    ?assertEqual(4, maps:get(match_size, Arena)),
    ?assertEqual(10, maps:get(max_players, Arena)),
    Minimal2 = maps:get(~"minimal", Modes),
    ?assertEqual(2, maps:get(match_size, Minimal2)),
    cleanup_temp_dir(TmpDir).

no_config_noop() ->
    TmpDir = make_temp_dir(),
    application:set_env(asobi, game_dir, TmpDir),
    application:set_env(asobi, game_modes, #{~"existing" => #{module => my_mod}}),
    ok = asobi_lua_config:maybe_load_game_config(),
    Modes = get_game_modes(),
    ?assert(is_map_key(~"existing", Modes)),
    cleanup_temp_dir(TmpDir).

bot_names_from_script() ->
    {ok, St0} = asobi_lua_loader:new(fixture("bots/named_bot.lua")),
    St = assert_luerl_state(St0),
    {ok, Val, St1} = luerl:get_table_keys([~"names"], St),
    Names = luerl:decode(Val, St1),
    NameList = [V || {_, V} <- ensure_list(Names), is_binary(V)],
    ?assertEqual([~"Spark", ~"Blitz", ~"Volt", ~"Neon", ~"Pulse"], NameList).

bot_names_fallback() ->
    {ok, St0} = asobi_lua_loader:new(fixture("bots/chaser.lua")),
    St = assert_luerl_state(St0),
    case luerl:get_table_keys([~"names"], St) of
        {ok, nil, _} -> ok;
        {ok, false, _} -> ok;
        _ -> ?assert(false)
    end.

world_config_zone_settings() ->
    TmpDir = make_temp_dir(),
    {ok, Content} = file:read_file(fixture("config_world.lua")),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), Content),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Modes = get_game_modes(),
    Mode = maps:get(~"default", Modes),
    ?assertEqual(true, maps:get(lazy_zones, Mode)),
    ?assertEqual(60000, maps:get(zone_idle_timeout, Mode)),
    ?assertEqual(500, maps:get(max_active_zones, Mode)),
    cleanup_temp_dir(TmpDir).

world_config_phase2_settings() ->
    TmpDir = make_temp_dir(),
    {ok, Content} = file:read_file(fixture("config_world_phase2.lua")),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), Content),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Modes = get_game_modes(),
    Mode = maps:get(~"default", Modes),
    ?assertEqual(64, maps:get(spatial_grid_cell_size, Mode)),
    ?assertEqual(5, maps:get(cold_tick_divisor, Mode)),
    ?assertEqual(true, maps:get(lazy_zones, Mode)),
    cleanup_temp_dir(TmpDir).

game_type_world_selects_world_bridge() ->
    TmpDir = make_temp_dir(),
    {ok, Content} = file:read_file(fixture("config_game_type_world.lua")),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), Content),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Modes = get_game_modes(),
    Mode = maps:get(~"default", Modes),
    ?assertEqual(world, maps:get(type, Mode)),
    {ok, GameMod, _} = asobi_game_modes:resolve_game_module(~"default"),
    ?assertEqual(asobi_lua_world, GameMod),
    cleanup_temp_dir(TmpDir).

game_type_absent_defaults_to_match() ->
    TmpDir = make_temp_dir(),
    {ok, Content} = file:read_file(fixture("config_minimal.lua")),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), Content),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Modes = get_game_modes(),
    Mode = maps:get(~"default", Modes),
    ?assertEqual(false, maps:is_key(type, Mode)),
    {ok, GameMod, _} = asobi_game_modes:resolve_game_module(~"default"),
    ?assertEqual(asobi_lua_match, GameMod),
    cleanup_temp_dir(TmpDir).

empty_grace_ms_forwarded() ->
    TmpDir = make_temp_dir(),
    {ok, Content} = file:read_file(fixture("config_grace.lua")),
    ok = file:write_file(filename:join(TmpDir, "match.lua"), Content),
    application:set_env(asobi, game_dir, TmpDir),
    ok = asobi_lua_config:maybe_load_game_config(),
    Modes = get_game_modes(),
    Mode = maps:get(~"default", Modes),
    ?assertEqual(30000, maps:get(empty_grace_ms, Mode)),
    cleanup_temp_dir(TmpDir).

%% --- Helpers ---

-spec get_game_modes() -> #{dynamic() => dynamic()}.
get_game_modes() ->
    case application:get_env(asobi, game_modes, #{}) of
        M when is_map(M) -> M;
        _ -> #{}
    end.

-spec assert_luerl_state(dynamic()) -> dynamic().
assert_luerl_state(St) when is_tuple(St), element(1, St) =:= luerl ->
    St.

-spec ensure_list(term()) -> list().
ensure_list(L) when is_list(L) -> L;
ensure_list(_) -> [].

make_temp_dir() ->
    TmpDir = "/tmp/asobi_lua_config_test_" ++ integer_to_list(erlang:unique_integer([positive])),
    ok = filelib:ensure_dir(filename:join(TmpDir, "dummy")),
    TmpDir.

cleanup_temp_dir(Dir) ->
    os:cmd("rm -rf " ++ Dir),
    ok.
