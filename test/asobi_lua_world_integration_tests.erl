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
    N = integer_to_binary(erlang:unique_integer([positive])),
    #{
        world_id => <<"lua_world_integration_", N/binary>>,
        game_module => asobi_lua_world,
        game_config => #{lua_script => fixture("world_server_integration.lua")},
        grid_size => 1,
        zone_size => 1200,
        tick_rate => 20,
        max_players => 8,
        view_radius => 0
    }.

start_world() ->
    ok = ensure_pg_scope(),
    {ok, InstancePid} = asobi_world_instance:start_link(world_config()),
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
            Probes = poll_until(
                fun() ->
                    Entities = asobi_zone:get_entities(ZonePid),
                    [
                        E
                     || {_Id, E} <- maps:to_list(Entities),
                        maps:get(~"type", E, undefined) =:= ~"object"
                    ]
                end,
                fun(Found) -> Found =/= [] end,
                2000
            ),
            ?assertEqual(1, length(Probes)),
            [Probe] = Probes,
            ?assertEqual(true, maps:get(~"solid", Probe))
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
