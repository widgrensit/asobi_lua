-module(asobi_bot_spawner_tests).
-include_lib("eunit/include/eunit.hrl").

%% #79: fill_mode/2 must never enqueue more bots than max_players allows,
%% even when min_players is larger. Without the cap, a match_size=2 /
%% max_players=2 mode with 1 human queued would add 3 bots (filling to the
%% spawner's hardcoded min_players default of 4) — enough to form the
%% human's match PLUS a spurious bot-vs-bot match.

fill_mode_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"fill never exceeds max_players even when min_players is larger",
            fun fill_capped_at_max_players/0},
        {"fill still reaches min_players when it fits under max_players",
            fun fill_reaches_min_players_under_cap/0},
        {"no bots added once queue already meets max_players", fun no_bots_when_already_at_cap/0}
    ]}.

setup() ->
    application:set_env(asobi, game_modes, #{}),
    meck:new(asobi_matchmaker, [non_strict, no_link]),
    meck:expect(asobi_matchmaker, add, fun(_BotId, _Opts) -> ok end),
    ok.

cleanup(_) ->
    meck:unload(asobi_matchmaker),
    application:unset_env(asobi, game_modes).

fill_capped_at_max_players() ->
    %% match_size = max_players = 2; bots.min_players left at the
    %% spawner's default (4). 1 human already queued.
    application:set_env(asobi, game_modes, #{
        ~"arena" => #{
            match_size => 2,
            max_players => 2,
            bots => #{enabled => true, min_players => 4}
        }
    }),
    asobi_bot_spawner:fill_mode(~"arena", 1),
    ?assertEqual(1, meck:num_calls(asobi_matchmaker, add, '_')).

fill_reaches_min_players_under_cap() ->
    %% max_players is generous (10); min_players = 4 is fully reachable.
    application:set_env(asobi, game_modes, #{
        ~"arena" => #{
            match_size => 4,
            max_players => 10,
            bots => #{enabled => true, min_players => 4}
        }
    }),
    asobi_bot_spawner:fill_mode(~"arena", 1),
    ?assertEqual(3, meck:num_calls(asobi_matchmaker, add, '_')).

no_bots_when_already_at_cap() ->
    application:set_env(asobi, game_modes, #{
        ~"arena" => #{
            match_size => 2,
            max_players => 2,
            bots => #{enabled => true, min_players => 4}
        }
    }),
    asobi_bot_spawner:fill_mode(~"arena", 2),
    ?assertEqual(0, meck:num_calls(asobi_matchmaker, add, '_')).
