-module(asobi_lua_world_integration_tests).
-include_lib("eunit/include/eunit.hrl").

%% asobi#246: spawn_templates/1, terrain_provider/1, and phases/1 all silently
%% no-op'd in production because asobi_world_server calls them with the raw
%% world config (no lua_state threaded through) - a shape none of the
%% existing unit tests exercised, since they all built their state via
%% asobi_lua_world:init/1 first. This boots a REAL asobi_world_instance (the
%% actual production entry point, from the asobi dependency this app already
%% has) with a Lua game module, so a regression here fails through the real
%% call path instead of a hand-built one.

-spec fixture(string()) -> file:filename_all().
fixture(Name) ->
    case code:lib_dir(asobi_lua) of
        {error, _} -> error(asobi_lua_not_loaded);
        Dir -> filename:absname(filename:join([Dir, "test", "fixtures", "lua", Name]))
    end.

ensure_pg_scope() ->
    case whereis(nova_scope) of
        undefined -> pg:start_link(nova_scope);
        _ -> ok
    end,
    ok.

world_config() ->
    world_config(fixture("world_server_integration.lua")).

world_config(ScriptPath) ->
    N = integer_to_binary(erlang:unique_integer([positive])),
    #{
        world_id => <<"lua_world_integration_", N/binary>>,
        game_module => asobi_lua_world,
        game_config => #{lua_script => ScriptPath},
        grid_size => 1,
        zone_size => 1200,
        tick_rate => 20,
        max_players => 8,
        view_radius => 0
    }.

start_world() ->
    start_world(world_config()).

start_world(Config) ->
    ok = ensure_pg_scope(),
    {ok, InstancePid} = asobi_world_instance:start_link(Config),
    unlink(InstancePid),
    %% loading -> running transition, same wait asobi_world_server_tests uses.
    timer:sleep(50),
    InstancePid.

spawn_templates_reach_a_real_zone_test_() ->
    {timeout, 10, fun() ->
        InstancePid = start_world(),
        try
            ZoneManagerPid = asobi_world_instance:get_child(InstancePid, asobi_zone_manager),
            {ok, ZonePid} = asobi_zone_manager:get_zone(ZoneManagerPid, {0, 0}),
            %% zone_tick spawns on tick 1, the spawn cast lands on a
            %% following tick - poll rather than a fixed sleep.
            %% The probe is inserted directly by game.zone.spawn, but the
            %% whole entity map round-trips through zone_tick's return value
            %% (decode_to_map + atomize_entities) on every subsequent tick
            %% regardless of whether the script touches it - see
            %% widgrensit/asobi#270 - so by the time this poll succeeds the
            %% probe's own keys are atoms too.
            Probes = poll_until(
                fun() ->
                    Entities = asobi_zone:get_entities(ZonePid),
                    [
                        E
                     || {_Id, E} <- maps:to_list(Entities),
                        maps:get(type, E, undefined) =:= ~"object"
                    ]
                end,
                fun(Found) -> Found =/= [] end,
                2000
            ),
            ?assertEqual(1, length(Probes)),
            [Probe] = Probes,
            ?assertEqual(true, maps:get(solid, Probe))
        after
            catch exit(InstancePid, shutdown)
        end
    end}.

phases_reach_the_world_server_test_() ->
    {timeout, 10, fun() ->
        InstancePid = start_world(),
        try
            WorldPid = asobi_world_instance:get_child(InstancePid, asobi_world_server),
            true = is_pid(WorldPid),
            Info = asobi_world_server:get_info(WorldPid),
            %% asobi_world_server:init/1 only calls asobi_phase:init/1 (which
            %% populates phase_state, and in turn get_info/1's `phase` key)
            %% when GameMod:phases/1 returns a non-empty list. If phases/1
            %% silently no-ops back to [] (asobi#246), this key is absent.
            ?assertMatch(#{phase := #{phase := ~"lobby"}}, Info)
        after
            catch exit(InstancePid, shutdown)
        end
    end}.

%% asobi#246 follow-up: fixing the silent no-op must not overcorrect into
%% false alarms. spawn_templates/1, terrain_provider/1, and phases/1 are all
%% documented OPTIONAL (see asobi_lua_world's moduledoc); a script that never
%% defines terrain_provider is not an error and must not reach the dev-error
%% telemetry channel.
absent_optional_callback_emits_no_game_error_test_() ->
    {timeout, 10, fun() ->
        {ok, _} = application:ensure_all_started(telemetry),
        Self = self(),
        Ref = make_ref(),
        telemetry:attach(
            Ref, [asobi, error], fun(_E, _M, Meta, _) -> Self ! {ev, Meta} end, []
        ),
        %% world_server_integration.lua defines no terrain_provider.
        InstancePid = start_world(),
        try
            receive
                {ev, Meta} -> erlang:error({unexpected_game_error, Meta})
            after 500 -> ok
            end
        after
            telemetry:detach(Ref),
            catch exit(InstancePid, shutdown)
        end
    end}.

%% Companion positive case: a callback that IS defined and raises must still
%% reach the dev-error channel - the is_defined/2 guard must not swallow real
%% failures along with absent-optional-callback silence.
defined_callback_error_emits_game_error_test_() ->
    {timeout, 10, fun() ->
        {ok, _} = application:ensure_all_started(telemetry),
        Self = self(),
        Ref = make_ref(),
        telemetry:attach(
            Ref, [asobi, error], fun(_E, _M, Meta, _) -> Self ! {ev, Meta} end, []
        ),
        Config = world_config(fixture("world_server_integration_broken_terrain.lua")),
        InstancePid = start_world(Config),
        try
            receive
                {ev, #{kind := lua_error, details := D}} ->
                    ?assertEqual(terrain_provider, maps:get(callback, D))
            after 2000 -> ?assert(false)
            end
        after
            telemetry:detach(Ref),
            catch exit(InstancePid, shutdown)
        end
    end}.

-spec poll_until(fun(() -> T), fun((T) -> boolean()), non_neg_integer()) -> T.
poll_until(Get, _Done, TimeoutMs) when TimeoutMs =< 0 ->
    Get();
poll_until(Get, Done, TimeoutMs) ->
    Value = Get(),
    case Done(Value) of
        true ->
            Value;
        false ->
            timer:sleep(20),
            poll_until(Get, Done, TimeoutMs - 20)
    end.
