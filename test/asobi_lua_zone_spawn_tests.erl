-module(asobi_lua_zone_spawn_tests).
-include_lib("eunit/include/eunit.hrl").

%% Per-zone Lua now runs regardless of how the zone was created: each zone
%% process builds its own Luerl VM from the script via init_zone_state/2, bound
%% to the zone pid, so game.zone.spawn reaches the live zone. These tests cover
%% the lazy/fresh path (init_zone_state from an empty zone_state), the snapshot
%% round-trip (dump_zone_state -> jsonb-safe map -> init_zone_state restore),
%% and the full lifecycle through a real asobi_zone.

-spec fixture(string()) -> file:filename_all().
fixture(Name) ->
    case code:lib_dir(asobi_lua) of
        {error, _} -> error(asobi_lua_not_loaded);
        Dir -> filename:absname(filename:join([Dir, "test", "fixtures", "lua", Name]))
    end.

setup() ->
    %% asobi_zone is a plain gen_server; it only needs the nova_scope pg group
    %% for pg:join. Starting the full asobi application would boot Nova, which
    %% isn't configured in this unit-test context.
    case whereis(nova_scope) of
        undefined -> pg:start_link(nova_scope);
        _ -> ok
    end,
    ok.

cleanup(_) ->
    ok.

zone_spawn_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"init_zone_state builds a VM from an empty (lazy) zone_state",
            fun init_zone_state_builds_vm/0},
        {"game_state round-trips through dump_zone_state/init_zone_state",
            fun game_state_round_trips/0},
        {"a never-seeded zone round-trips as nil, not an empty table",
            fun unseeded_game_state_round_trips_as_nil/0},
        {"dump_zone_state without a VM stays jsonb-safe", fun dump_without_vm_is_jsonb_safe/0},
        {"game.zone.spawn from Lua reaches a live zone built via handle_continue",
            fun lua_spawn_reaches_zone/0}
    ]}.

zone_config() ->
    #{
        world_id => ~"spawn_world",
        coords => {0, 0},
        game_module => asobi_lua_world,
        game_config => #{lua_script => fixture("spawn_world.lua")},
        world_server_pid => self()
    }.

init_zone_state_builds_vm() ->
    %% Lazy zones start with no zone_state; init_zone_state must still produce a
    %% usable VM bound to the zone pid.
    ZoneState = asobi_lua_world:init_zone_state(zone_config(), #{}),
    ?assert(maps:is_key(lua_state, ZoneState)),
    ?assertEqual(nil, maps:get(game_state, ZoneState)).

game_state_round_trips() ->
    erlang:erase({asobi_lua_world, zone_state}),
    ZoneState0 = asobi_lua_world:init_zone_state(zone_config(), #{}),
    %% One tick lets the script stamp gameplay state (seeded = true). The spawn
    %% casts it emits go to self() here and are harmless.
    {_Ents, ZoneState1} = asobi_lua_world:zone_tick(#{}, ZoneState0),
    flush_casts(),

    Dumped = asobi_lua_world:dump_zone_state(ZoneState1),
    ?assertEqual(#{~"game_state" => #{~"seeded" => true}}, Dumped),
    ?assertNot(maps:is_key(lua_state, Dumped)),
    %% jsonb-safe: must encode without raising.
    _ = json:encode(Dumped),

    %% Restoring re-encodes the gameplay state into a fresh VM.
    Restored = asobi_lua_world:init_zone_state(zone_config(), Dumped),
    ?assertEqual(
        #{~"game_state" => #{~"seeded" => true}}, asobi_lua_world:dump_zone_state(Restored)
    ),
    erlang:erase({asobi_lua_world, zone_state}).

lua_spawn_reaches_zone() ->
    %% Templates come from the script, exactly as asobi_world_server wires them.
    {ok, WorldState} = asobi_lua_world:init(#{lua_script => fixture("spawn_world.lua")}),
    Templates = asobi_lua_world:spawn_templates(WorldState),
    ?assertMatch(#{~"goblin" := _, ~"chest" := _}, Templates),

    %% Note: NO pre-injected lua_state. The zone builds its own VM in
    %% handle_continue, mirroring a lazy zone.
    {ok, ZonePid} = asobi_zone:start_link(#{
        world_id => ~"spawn_world",
        coords => {0, 0},
        ticker_pid => self(),
        game_module => asobi_lua_world,
        game_config => #{lua_script => fixture("spawn_world.lua")},
        world_server_pid => self(),
        spawn_templates => Templates
    }),

    erlang:erase({asobi_lua_world, zone_state}),
    gen_server:cast(ZonePid, {tick, 1}),
    %% First call flushes the tick (which enqueues the spawn casts); the second
    %% flushes those spawn casts so the entities are present.
    _ = asobi_zone:get_entities(ZonePid),
    Entities = asobi_zone:get_entities(ZonePid),

    Goblins = by_type(~"npc", Entities),
    Chests = by_type(~"object", Entities),
    ?assertEqual(1, length(Goblins)),
    ?assertEqual(1, length(Chests)),

    [Goblin] = Goblins,
    ?assert(maps:get(~"health", Goblin) == 100),
    ?assertEqual(~"patrol", maps:get(~"ai", Goblin)),

    [Chest] = Chests,
    ?assertEqual(~"rare", maps:get(~"loot", Chest)),

    gen_server:stop(ZonePid),
    erlang:erase({asobi_lua_world, zone_state}).

unseeded_game_state_round_trips_as_nil() ->
    %% A zone snapshotted before its first seeding tick has game_state = nil.
    %% It must come back nil (null over jsonb), not an empty table, so the
    %% script's `game_state == nil` init guard still fires after recovery.
    ZoneState0 = asobi_lua_world:init_zone_state(zone_config(), #{}),
    ?assertEqual(nil, maps:get(game_state, ZoneState0)),
    Dumped = asobi_lua_world:dump_zone_state(ZoneState0),
    ?assertEqual(#{~"game_state" => null}, Dumped),
    _ = json:encode(Dumped),
    Restored = asobi_lua_world:init_zone_state(zone_config(), Dumped),
    ?assertEqual(nil, maps:get(game_state, Restored)).

dump_without_vm_is_jsonb_safe() ->
    %% When init_zone_state fails to build a VM it returns the bare zone_state
    %% (no lua_state); dumping that degraded zone must still be jsonb-safe.
    Raw = #{~"game_state" => #{~"hp" => 10}, ~"misc" => 1},
    Dumped = asobi_lua_world:dump_zone_state(Raw),
    ?assertNot(maps:is_key(lua_state, Dumped)),
    _ = json:encode(Dumped),
    ?assertEqual(Raw, Dumped).

by_type(Type, Entities) ->
    [E || {_Id, E} <- maps:to_list(Entities), maps:get(type, E, undefined) =:= Type].

flush_casts() ->
    receive
        _ -> flush_casts()
    after 0 -> ok
    end.
