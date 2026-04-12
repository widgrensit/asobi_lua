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
        {"game.economy.grant calls engine", fun game_economy_grant/0},
        {"game.economy.debit calls engine", fun game_economy_debit/0},
        {"game.leaderboard.submit calls server", fun game_lb_submit/0},
        {"game.notify sends notification", fun game_notify/0},
        {"game.chat.send sends message", fun game_chat_send/0},
        {"api installed in match init", fun api_in_match_init/0},
        {"game api callable from lua script", fun game_api_from_script/0},
        {"game.spatial.query_radius returns results", fun spatial_query_radius/0},
        {"game.spatial.nearest returns closest", fun spatial_nearest/0},
        {"game.spatial.in_range checks distance", fun spatial_in_range/0},
        {"game.spatial.distance returns distance", fun spatial_distance/0},
        {"game.zone.spawn calls zone", fun zone_spawn/0},
        {"game.zone.despawn calls zone", fun zone_despawn/0}
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
        asobi_zone
    ]).

%% --- Test cases ---

game_id() ->
    St = install_api(),
    {ok, [Id | _], _} = asobi_lua_loader:call([~"game", ~"id"], [], St),
    ?assertEqual(~"test-uuid-v7", Id).

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

%% --- Helpers ---

install_api() ->
    {ok, St0} = asobi_lua_loader:new(fixture("test_match.lua")),
    Ctx = #{match_id => ~"test-match", match_pid => self()},
    asobi_lua_api:install(Ctx, St0).

install_api_with_zone() ->
    {ok, St0} = asobi_lua_loader:new(fixture("test_match.lua")),
    Ctx = #{match_id => ~"test-match", match_pid => self(), zone_pid => self()},
    asobi_lua_api:install(Ctx, St0).

-spec eval(string(), dynamic()) -> {ok, [term()], dynamic()} | {error, term()}.
eval(Code, St) ->
    case luerl:do(Code, St) of
        {ok, Results, St1} -> {ok, Results, St1};
        Other -> Other
    end.
