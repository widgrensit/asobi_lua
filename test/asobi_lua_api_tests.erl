-module(asobi_lua_api_tests).
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

%% --- Tests ---

api_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"game.id returns binary", fun game_id/0},
        {"game.broadcast forwards to match server", fun game_broadcast/0},
        {"game.send forwards to presence", fun game_send/0},
        {"game.economy.grant calls engine", fun game_economy_grant/0},
        {"game.economy.debit calls engine", fun game_economy_debit/0},
        {"game.economy.balance returns wallets", fun game_economy_balance/0},
        {"game.economy.purchase returns ok", fun game_economy_purchase/0},
        {"game.leaderboard.submit calls server", fun game_lb_submit/0},
        {"game.leaderboard.top returns entries", fun game_lb_top/0},
        {"game.leaderboard.rank returns rank", fun game_lb_rank/0},
        {"game.leaderboard.around returns entries", fun game_lb_around/0},
        {"game.notify sends notification", fun game_notify/0},
        {"game.notify_many forwards ids", fun game_notify_many/0},
        {"game.storage.get reads doc", fun game_storage_get/0},
        {"game.storage.set writes doc", fun game_storage_set/0},
        {"game.storage.player_get reads player doc", fun game_storage_player_get/0},
        {"game.storage.player_set writes player doc", fun game_storage_player_set/0},
        {"game.chat.send sends message", fun game_chat_send/0},
        {"api installed in match init", fun api_in_match_init/0},
        {"game api callable from lua script", fun game_api_from_script/0},
        {"game.spatial.query_radius returns results", fun spatial_query_radius/0},
        {"game.spatial.query_radius opts filter by type", fun spatial_query_radius_with_opts/0},
        {"game.spatial.nearest returns closest", fun spatial_nearest/0},
        {"game.spatial.nearest opts forwards max_results", fun spatial_nearest_with_opts/0},
        {"game.spatial.in_range checks distance", fun spatial_in_range/0},
        {"game.spatial.distance returns distance", fun spatial_distance/0},
        {"game.zone.spawn calls zone", fun zone_spawn/0},
        {"game.zone.spawn with overrides forwards them", fun zone_spawn_with_overrides/0},
        {"game.zone.despawn calls zone", fun zone_despawn/0},
        {"game.spatial.query_radius zone-based", fun spatial_zone_query_radius/0},
        {"game.spatial.query_rect zone-based", fun spatial_zone_query_rect/0},
        {"game.spatial.query_rect errors without zone", fun spatial_query_rect_no_zone/0},
        {"game.terrain.get_chunk returns data", fun terrain_get_chunk/0},
        {"game.terrain.get_chunk errors without store", fun terrain_get_chunk_no_store/0},
        {"game.terrain.preload forwards coords", fun terrain_preload/0}
    ]}.

setup() ->
    meck:new(asobi_id, [no_link]),
    meck:expect(asobi_id, generate, fun() -> ~"test-uuid-v7" end),
    meck:new(asobi_match_server, [no_link]),
    meck:expect(asobi_match_server, broadcast_event, fun(_, _, _) -> ok end),
    meck:new(asobi_presence, [non_strict, no_link]),
    meck:expect(asobi_presence, send, fun(_, _) -> ok end),
    meck:new(asobi_economy, [no_link]),
    meck:expect(asobi_economy, grant, fun(_, _, _, _) ->
        {ok, #{~"currency" => ~"gold", ~"balance" => 500}}
    end),
    meck:expect(asobi_economy, debit, fun(_, _, _, _) ->
        {ok, #{~"currency" => ~"gold", ~"balance" => 450}}
    end),
    meck:expect(asobi_economy, get_wallets, fun(_) ->
        {ok, [#{currency => ~"gold", balance => 500}]}
    end),
    meck:expect(asobi_economy, purchase, fun(_, _) ->
        {ok, #{~"item" => ~"sword"}}
    end),
    meck:new(asobi_leaderboard_server, [no_link]),
    meck:expect(asobi_leaderboard_server, submit, fun(_, _, _) -> ok end),
    meck:expect(asobi_leaderboard_server, top, fun(_, _) ->
        [{~"p1", 100, 1}, {~"p2", 80, 2}]
    end),
    meck:expect(asobi_leaderboard_server, rank, fun(_, _) -> {ok, 3} end),
    meck:expect(asobi_leaderboard_server, around, fun(_, _, _) ->
        [{~"p1", 100, 1}]
    end),
    meck:new(asobi_notify, [no_link]),
    meck:expect(asobi_notify, send, fun(_, _, _, _) -> {ok, #{}} end),
    meck:expect(asobi_notify, send_many, fun(Ids, _, _, _) -> Ids end),
    meck:new(asobi_repo, [no_link]),
    meck:expect(asobi_repo, all, fun(_) -> {ok, []} end),
    meck:expect(asobi_repo, insert, fun(_) -> {ok, #{value => #{}}} end),
    meck:expect(asobi_repo, insert, fun(_, _) -> {ok, #{value => #{}}} end),
    meck:expect(asobi_repo, update_all, fun(_, _) -> {ok, 1} end),
    meck:new(asobi_chat_channel, [no_link]),
    meck:expect(asobi_chat_channel, send_message, fun(_, _, _) -> ok end),
    meck:new(asobi_zone, [no_link]),
    meck:expect(asobi_zone, spawn_entity, fun(_, _, _) -> ok end),
    meck:expect(asobi_zone, spawn_entity, fun(_, _, _, _) -> ok end),
    meck:expect(asobi_zone, despawn_entity, fun(_, _) -> ok end),
    meck:expect(asobi_zone, query_radius, fun(_, _, _) ->
        [{~"e1", {5.0, 5.0}}, {~"e2", {3.0, 4.0}}]
    end),
    meck:expect(asobi_zone, query_rect, fun(_, _, _) ->
        [{~"e1", {5.0, 5.0}}]
    end),
    meck:new(asobi_terrain_store, [no_link]),
    meck:expect(asobi_terrain_store, get_chunk, fun(_, _) ->
        {ok, #{~"tiles" => [1, 2, 3]}}
    end),
    meck:expect(asobi_terrain_store, preload_chunks, fun(_, _) -> ok end),
    ok.

cleanup(_) ->
    meck:unload([
        asobi_id,
        asobi_match_server,
        asobi_presence,
        asobi_economy,
        asobi_leaderboard_server,
        asobi_notify,
        asobi_repo,
        asobi_chat_channel,
        asobi_zone,
        asobi_terrain_store
    ]).

%% --- Test cases ---

game_id() ->
    St = install_api(),
    {ok, [Id | _], _} = asobi_lua_loader:call([~"game", ~"id"], [], St),
    ?assertEqual(~"test-uuid-v7", Id).

game_broadcast() ->
    St = install_api(),
    Code = "return game.broadcast('hello', { msg = 'world' })",
    {ok, [true | _], _} = eval(Code, St),
    %% broadcast uses the live match_pid (self() in the test fixture),
    %% not the match_id binary.
    ?assert(meck:called(asobi_match_server, broadcast_event, [self(), ~"hello", '_'])).

game_send() ->
    St = install_api(),
    Code = "return game.send('p1', { kind = 'hello' })",
    {ok, [true | _], _} = eval(Code, St),
    ?assert(meck:called(asobi_presence, send, [~"p1", '_'])).

game_economy_balance() ->
    St = install_api(),
    Code = "local r = game.economy.balance('p1')\nreturn r.ok ~= nil",
    {ok, [true | _], _} = eval(Code, St),
    ?assert(meck:called(asobi_economy, get_wallets, [~"p1"])).

game_economy_purchase() ->
    St = install_api(),
    Code = "local r = game.economy.purchase('p1', 'sword')\nreturn r.ok ~= nil",
    {ok, [true | _], _} = eval(Code, St),
    ?assert(meck:called(asobi_economy, purchase, [~"p1", ~"sword"])).

game_lb_top() ->
    St = install_api(),
    Code =
        "local r = game.leaderboard.top('kills', 10)\n"
        "return #r.ok",
    {ok, [Count | _], _} = eval(Code, St),
    ?assertEqual(2, trunc(Count)),
    ?assert(meck:called(asobi_leaderboard_server, top, [~"kills", 10])).

game_lb_rank() ->
    St = install_api(),
    Code = "local r = game.leaderboard.rank('kills', 'p1')\nreturn r.ok",
    {ok, [Rank | _], _} = eval(Code, St),
    ?assertEqual(3, trunc(Rank)).

game_lb_around() ->
    St = install_api(),
    Code = "local r = game.leaderboard.around('kills', 'p1', 5)\nreturn #r.ok",
    {ok, [Count | _], _} = eval(Code, St),
    ?assertEqual(1, trunc(Count)).

game_notify_many() ->
    St = install_api(),
    Code = "local r = game.notify_many({'p1','p2'}, 'reward', 'gg')\nreturn #r.ok",
    {ok, [Count | _], _} = eval(Code, St),
    ?assertEqual(2, trunc(Count)),
    ?assert(meck:called(asobi_notify, send_many, '_')).

game_storage_get() ->
    St = install_api(),
    Code =
        "local r = game.storage.get('settings', 'theme')\n"
        "return r.error ~= nil",
    %% mocked asobi_repo:all returns {ok, []} which the bridge treats as
    %% not_found; the wrap_result helper turns that into {error, ...}
    {ok, [true | _], _} = eval(Code, St).

game_storage_set() ->
    St = install_api(),
    Code =
        "local r = game.storage.set('settings', 'theme', { value = 'dark' })\nreturn r.ok ~= nil",
    {ok, [true | _], _} = eval(Code, St).

game_storage_player_get() ->
    St = install_api(),
    Code = "local r = game.storage.player_get('p1', 'inventory', 'gold')\nreturn r.error ~= nil",
    {ok, [true | _], _} = eval(Code, St).

game_storage_player_set() ->
    St = install_api(),
    Code =
        "local r = game.storage.player_set('p1', 'inventory', 'gold', { count = 50 })\nreturn r.ok ~= nil",
    {ok, [true | _], _} = eval(Code, St).

game_economy_grant() ->
    St = install_api(),
    %% Call via Lua code to get proper arg encoding
    Code = "return game.economy.grant('p1', 'gold', 100, 'reward')",
    {ok, [Result | _], St1} = eval(Code, St),
    ?assert(meck:called(asobi_economy, grant, [~"p1", ~"gold", 100, '_'])),
    Decoded = luerl:decode(Result, St1),
    ?assert(lists:keymember(~"ok", 1, Decoded)).

game_economy_debit() ->
    St = install_api(),
    Code = "return game.economy.debit('p1', 'gold', 50, 'cost')",
    {ok, [Result | _], St1} = eval(Code, St),
    ?assert(meck:called(asobi_economy, debit, [~"p1", ~"gold", 50, '_'])),
    Decoded = luerl:decode(Result, St1),
    ?assert(lists:keymember(~"ok", 1, Decoded)).

game_lb_submit() ->
    St = install_api(),
    Code = "return game.leaderboard.submit('kills', 'p1', 42)",
    {ok, [true | _], _} = eval(Code, St),
    ?assert(meck:called(asobi_leaderboard_server, submit, [~"kills", ~"p1", 42])).

game_notify() ->
    St = install_api(),
    Code = "return game.notify('p1', 'reward', 'You won!')",
    {ok, [Result | _], St1} = eval(Code, St),
    ?assert(meck:called(asobi_notify, send, [~"p1", ~"reward", ~"You won!", '_'])),
    Decoded = luerl:decode(Result, St1),
    ?assert(lists:keymember(~"ok", 1, Decoded)).

game_chat_send() ->
    St = install_api(),
    Code = "return game.chat.send('match_123', 'p1', 'gg')",
    {ok, [true | _], _} = eval(Code, St),
    ?assert(meck:called(asobi_chat_channel, send_message, [~"match_123", ~"p1", ~"gg"])).

api_in_match_init() ->
    Config = #{lua_script => fixture("test_match.lua"), match_id => ~"test-match-1"},
    {ok, State} = asobi_lua_match:init(Config),
    ?assert(is_map(State)),
    #{lua_state := LuaSt} = State,
    {ok, [Id | _], _} = asobi_lua_loader:call([~"game", ~"id"], [], LuaSt),
    ?assertEqual(~"test-uuid-v7", Id).

game_api_from_script() ->
    St = install_api(),
    %% Test multiple API calls from Lua
    Code =
        "local id = game.id()\n"
        "game.leaderboard.submit('test', 'p1', 99)\n"
        "return id",
    {ok, [Id | _], _} = eval(Code, St),
    ?assertEqual(~"test-uuid-v7", Id),
    ?assert(meck:called(asobi_leaderboard_server, submit, [~"test", ~"p1", 99])).

spatial_query_radius() ->
    St = install_api(),
    Code =
        "local entities = {\n"
        "  a = { x = 0.0, y = 0.0, type = 'npc' },\n"
        "  b = { x = 3.0, y = 4.0, type = 'npc' },\n"
        "  c = { x = 100.0, y = 100.0, type = 'npc' }\n"
        "}\n"
        "local results = game.spatial.query_radius(entities, 0.0, 0.0, 6.0)\n"
        "local count = 0\n"
        "for _ in pairs(results) do count = count + 1 end\n"
        "return count",
    {ok, [Count | _], _} = eval(Code, St),
    ?assertEqual(2, trunc(Count)).

spatial_nearest() ->
    St = install_api(),
    Code =
        "local entities = {\n"
        "  a = { x = 10.0, y = 10.0, type = 'npc' },\n"
        "  b = { x = 1.0, y = 1.0, type = 'npc' }\n"
        "}\n"
        "local results = game.spatial.nearest(entities, 0.0, 0.0, 1)\n"
        "return results[1].id",
    {ok, [Id | _], _} = eval(Code, St),
    ?assertEqual(~"b", Id).

spatial_in_range() ->
    St = install_api(),
    Code =
        "local a = { x = 0.0, y = 0.0 }\n"
        "local b = { x = 3.0, y = 4.0 }\n"
        "return game.spatial.in_range(a, b, 5.0)",
    {ok, [true | _], _} = eval(Code, St).

spatial_distance() ->
    St = install_api(),
    Code =
        "local a = { x = 0.0, y = 0.0 }\n"
        "local b = { x = 3.0, y = 4.0 }\n"
        "return game.spatial.distance(a, b)",
    {ok, [D | _], _} = eval(Code, St),
    ?assert(abs(D - 5.0) < 0.001).

zone_spawn() ->
    St = install_api_with_zone(),
    Code = "return game.zone.spawn('goblin', 10.0, 20.0)",
    {ok, [true | _], _} = eval(Code, St),
    ?assert(meck:called(asobi_zone, spawn_entity, '_')).

zone_despawn() ->
    St = install_api_with_zone(),
    Code = "return game.zone.despawn('entity-123')",
    {ok, [true | _], _} = eval(Code, St),
    ?assert(meck:called(asobi_zone, despawn_entity, '_')).

spatial_zone_query_radius() ->
    St = install_api_with_zone(),
    Code =
        "local results = game.spatial.query_radius(0.0, 0.0, 10.0)\n"
        "local count = 0\n"
        "for _ in pairs(results) do count = count + 1 end\n"
        "return count",
    {ok, [Count | _], _} = eval(Code, St),
    ?assertEqual(2, trunc(Count)),
    ?assert(meck:called(asobi_zone, query_radius, '_')).

spatial_zone_query_rect() ->
    St = install_api_with_zone(),
    Code =
        "local results = game.spatial.query_rect(0.0, 0.0, 10.0, 10.0)\n"
        "local count = 0\n"
        "for _ in pairs(results) do count = count + 1 end\n"
        "return count",
    {ok, [Count | _], _} = eval(Code, St),
    ?assertEqual(1, trunc(Count)),
    ?assert(meck:called(asobi_zone, query_rect, '_')).

spatial_query_rect_no_zone() ->
    St = install_api(),
    Code = "return game.spatial.query_rect(0.0, 0.0, 10.0, 10.0)",
    {ok, [Result | _], St1} = eval(Code, St),
    Decoded = luerl:decode(Result, St1),
    ?assert(lists:keymember(~"error", 1, Decoded)).

spatial_query_radius_with_opts() ->
    St = install_api(),
    %% A regression that drops the opts arg would break entity-type
    %% filtering — meck_history confirms the 4-arg variant fires.
    meck:expect(asobi_spatial, query_radius, fun(_, _, _, _) ->
        [{~"e1", #{type => ~"npc"}, 4.0}]
    end),
    Code =
        "local entities = { a = { x = 0.0, y = 0.0, type = 'npc' } }\n"
        "local r = game.spatial.query_radius(entities, 0.0, 0.0, 10.0, { type = 'npc' })\n"
        "return #r",
    {ok, [Count | _], _} = eval(Code, St),
    ?assertEqual(1, trunc(Count)),
    ?assert(meck:called(asobi_spatial, query_radius, '_')).

spatial_nearest_with_opts() ->
    St = install_api(),
    meck:expect(asobi_spatial, nearest, fun(_, _, _, _) ->
        [{~"e1", #{type => ~"npc"}, 1.0}]
    end),
    Code =
        "local entities = { a = { x = 0.0, y = 0.0, type = 'npc' } }\n"
        "local r = game.spatial.nearest(entities, 0.0, 0.0, 1, { max_results = 1 })\n"
        "return #r",
    {ok, [Count | _], _} = eval(Code, St),
    ?assertEqual(1, trunc(Count)),
    ?assert(meck:called(asobi_spatial, nearest, '_')).

zone_spawn_with_overrides() ->
    St = install_api_with_zone(),
    Code = "return game.zone.spawn('goblin', 10.0, 20.0, { hp = 50 })",
    {ok, [true | _], _} = eval(Code, St),
    ?assert(meck:called(asobi_zone, spawn_entity, [self(), ~"goblin", '_', '_'])).

terrain_get_chunk() ->
    St = install_api_with_terrain(),
    Code = "local r = game.terrain.get_chunk(0, 0)\nreturn r.ok ~= nil",
    {ok, [true | _], _} = eval(Code, St),
    ?assert(meck:called(asobi_terrain_store, get_chunk, '_')).

terrain_get_chunk_no_store() ->
    St = install_api(),
    Code = "local r = game.terrain.get_chunk(0, 0)\nreturn r.error ~= nil",
    {ok, [true | _], _} = eval(Code, St).

terrain_preload() ->
    St = install_api_with_terrain(),
    Code = "return game.terrain.preload({ { cx = 0, cy = 0 }, { cx = 1, cy = 0 } })",
    {ok, [true | _], _} = eval(Code, St),
    ?assert(meck:called(asobi_terrain_store, preload_chunks, '_')).

%% --- Helpers ---

install_api() ->
    {ok, St0} = asobi_lua_loader:new(fixture("test_match.lua")),
    Ctx = #{match_id => ~"test-match", match_pid => self()},
    asobi_lua_api:install(Ctx, St0).

install_api_with_zone() ->
    {ok, St0} = asobi_lua_loader:new(fixture("test_match.lua")),
    Ctx = #{match_id => ~"test-match", match_pid => self(), zone_pid => self()},
    asobi_lua_api:install(Ctx, St0).

install_api_with_terrain() ->
    {ok, St0} = asobi_lua_loader:new(fixture("test_match.lua")),
    Ctx = #{
        match_id => ~"test-match",
        match_pid => self(),
        zone_pid => self(),
        terrain_store_pid => self()
    },
    asobi_lua_api:install(Ctx, St0).

-spec eval(string(), dynamic()) -> {ok, [term()], dynamic()} | {error, term()}.
eval(Code, St) ->
    case luerl:do(Code, St) of
        {ok, Results, St1} -> {ok, Results, St1};
        Other -> Other
    end.
