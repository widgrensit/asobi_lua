-module(asobi_lua_game_log_tests).
-include_lib("eunit/include/eunit.hrl").

-export([log/2]).

game_log_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"logs a string message with script context", fun logs_string/0},
        {"warn maps to warning level", fun warn_maps_to_warning/0},
        {"invalid level returns error envelope", fun invalid_level/0},
        {"wrong args return error envelope", fun wrong_args/0},
        {"table message renders as json", fun table_message/0},
        {"long message is bounded", fun long_message_bounded/0},
        {"meta table is forwarded", fun meta_forwarded/0},
        {"oversized meta is truncated", fun meta_truncated/0},
        {"per-key deny returns false and skips global", fun per_key_denied/0},
        {"global deny returns false", fun global_denied/0},
        {"missing limiters fail closed", fun no_limiter_fails_closed/0},
        {"zone context keys on zone pid", fun zone_keyed_on_pid/0}
    ]}.

setup() ->
    OldPrimary = logger:get_primary_config(),
    ok = logger:set_primary_config(level, all),
    ok = logger:add_handler(?MODULE, ?MODULE, #{config => undefined, level => all}),
    meck:new(seki, [no_link, passthrough]),
    meck:expect(seki, check, fun(_, _) -> {allow, 1} end),
    OldPrimary.

%% eunit runs each foreach test in its own process, so the receiving pid
%% must be attached per-test, not captured in setup.
attach() ->
    ok = logger:set_handler_config(?MODULE, config, self()).

cleanup(OldPrimary) ->
    _ = logger:remove_handler(?MODULE),
    ok = logger:set_primary_config(OldPrimary),
    meck:unload(seki).

log(#{level := Level, msg := {report, Report}}, #{config := Pid}) ->
    Pid ! {game_log, Level, Report};
log(_, _) ->
    ok.

install_api() ->
    install_api(#{match_id => ~"m1", match_pid => self(), script => ~"priv/lua/game.lua"}).

install_api(Ctx) ->
    {ok, St0} = asobi_lua_loader:new(fixture("test_match.lua")),
    asobi_lua_api:install(Ctx, St0).

fixture(Name) ->
    Dir =
        case code:lib_dir(asobi_lua) of
            {error, bad_name} -> error(asobi_lua_not_loaded);
            D -> D
        end,
    filename:join([Dir, "test", "fixtures", "lua", Name]).

eval(Code, St) ->
    luerl:do(Code, St).

recv_report() ->
    receive
        {game_log, Level, Report} -> {Level, Report}
    after 1000 -> error(no_log_received)
    end.

logs_string() ->
    attach(),
    St = install_api(),
    {ok, [true | _], _} = eval("return game.log('info', 'hello world')", St),
    {info, Report} = recv_report(),
    ?assertEqual(~"game.log", maps:get(msg, Report)),
    ?assertEqual(~"game.lua", maps:get(script, Report)),
    ?assertEqual(~"m1", maps:get(match_id, Report)),
    ?assertEqual(match, maps:get(context, Report)),
    ?assertEqual(~"hello world", maps:get(message, Report)),
    ?assertNot(maps:is_key(meta, Report)).

warn_maps_to_warning() ->
    attach(),
    St = install_api(),
    {ok, [true | _], _} = eval("return game.log('warn', 'careful')", St),
    {warning, _} = recv_report().

invalid_level() ->
    attach(),
    St = install_api(),
    {ok, [Res | _], _} = eval("local r = game.log('shout', 'x') return r.error ~= nil", St),
    ?assertEqual(true, Res),
    receive
        {game_log, _, _} -> error(unexpected_log)
    after 50 -> ok
    end.

wrong_args() ->
    St = install_api(),
    {ok, [Res | _], _} = eval("local r = game.log(42) return r.error ~= nil", St),
    ?assertEqual(true, Res).

table_message() ->
    attach(),
    St = install_api(),
    {ok, [true | _], _} = eval("return game.log('info', { hp = 10, name = 'goblin' })", St),
    {info, Report} = recv_report(),
    Msg = maps:get(message, Report),
    ?assertMatch({_, _}, binary:match(Msg, ~"goblin")),
    ?assertMatch({_, _}, binary:match(Msg, ~"10")).

long_message_bounded() ->
    attach(),
    St = install_api(),
    {ok, [true | _], _} = eval("return game.log('info', string.rep('x', 5000))", St),
    {info, Report} = recv_report(),
    ?assert(string:length(maps:get(message, Report)) =< 500).

meta_forwarded() ->
    attach(),
    St = install_api(),
    {ok, [true | _], _} = eval("return game.log('info', 'spawn', { id = 'e1', hp = 5 })", St),
    {info, Report} = recv_report(),
    ?assertEqual(#{~"id" => ~"e1", ~"hp" => 5}, maps:get(meta, Report)).

meta_truncated() ->
    attach(),
    St = install_api(),
    {ok, [true | _], _} = eval(
        "return game.log('info', 'big', { blob = string.rep('x', 4000) })", St
    ),
    {info, Report} = recv_report(),
    ?assertEqual(#{~"_truncated" => true}, maps:get(meta, Report)).

per_key_denied() ->
    meck:expect(seki, check, fun
        (asobi_lua_log_limiter, _) -> {deny, 0};
        (asobi_lua_log_global_limiter, _) -> error(should_not_be_spent)
    end),
    St = install_api(),
    {ok, [false | _], _} = eval("return game.log('info', 'dropped')", St),
    ?assertEqual(1, meck:num_calls(seki, check, [asobi_lua_log_limiter, '_'])).

global_denied() ->
    meck:expect(seki, check, fun
        (asobi_lua_log_limiter, _) -> {allow, 1};
        (asobi_lua_log_global_limiter, _) -> {deny, 0}
    end),
    St = install_api(),
    {ok, [false | _], _} = eval("return game.log('info', 'dropped')", St).

no_limiter_fails_closed() ->
    meck:expect(seki, check, fun(_, _) -> error(limiter_not_registered) end),
    St = install_api(),
    {ok, [false | _], _} = eval("return game.log('info', 'nowhere to go')", St).

zone_keyed_on_pid() ->
    attach(),
    Self = self(),
    meck:expect(seki, check, fun
        (asobi_lua_log_limiter, Key) when Key =:= Self -> {allow, 1};
        (asobi_lua_log_global_limiter, _) -> {allow, 1};
        (asobi_lua_log_limiter, Other) -> error({wrong_key, Other})
    end),
    St = install_api(#{
        match_id => ~"world-1",
        match_pid => self(),
        zone_pid => self(),
        script => ~"world.lua"
    }),
    {ok, [true | _], _} = eval("return game.log('info', 'from zone')", St),
    {info, Report} = recv_report(),
    ?assertEqual(zone, maps:get(context, Report)).
