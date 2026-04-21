-module(asobi_lua_world).
-moduledoc """
An `asobi_world` implementation that delegates all callbacks to Lua scripts
via Luerl.

The Lua script must define these functions:

```lua
function init(config)                        -- return initial game state
function join(player_id, state)              -- return updated state
function leave(player_id, state)             -- return updated state
function spawn_position(player_id, state)    -- return {x, y}
function zone_tick(entities, zone_state)     -- return entities, zone_state
function handle_input(player_id, input, entities) -- return entities
function post_tick(tick, state)              -- return state (or state + vote/finished)
-- Optional:
function generate_world(seed, config)        -- return zone_states table
function get_state(player_id, state)         -- return state visible to player
function vote_resolved(template, result, state) -- return updated state
function phases(config)                      -- return list of phase definitions
function on_phase_started(phase_name, state) -- return updated state
function on_phase_ended(phase_name, state)   -- return updated state
function spawn_templates(config)             -- return template registry table
function on_world_recovered(snapshots, state) -- return updated state
function terrain_provider(config)            -- return {module, args} or nil
function on_zone_loaded(cx, cy, state)       -- return zone_state, state
function on_zone_unloaded(cx, cy, state)     -- return state
```
""".

-behaviour(asobi_world).

-export([init/1, join/2, leave/2, spawn_position/2]).
-export([zone_tick/2, handle_input/3, post_tick/2]).
-export([generate_world/2, get_state/2]).
-export([phases/1, on_phase_started/2, on_phase_ended/2]).
-export([spawn_templates/1, on_world_recovered/2]).
-export([terrain_provider/1, on_zone_loaded/2, on_zone_unloaded/2]).

-define(TICK_TIMEOUT, 500).

-spec init(map()) -> {ok, map()}.
init(Config) ->
    ScriptPath =
        case maps:get(lua_script, Config, undefined) of
            P when is_binary(P); is_list(P) ->
                P;
            undefined ->
                logger:error(#{msg => ~"asobi_lua_world init: missing lua_script", config => Config}),
                erlang:error({missing_lua_script, Config})
        end,
    GameConfig = maps:get(game_config, Config, #{}),
    case asobi_lua_loader:new(ScriptPath) of
        {ok, LuaSt0} ->
            Ctx = #{
                match_id => maps:get(match_id, Config, undefined),
                match_pid => self()
            },
            LuaSt0a = asobi_lua_api:install(Ctx, LuaSt0),
            {EncConfig, LuaSt1} = luerl:encode(GameConfig, LuaSt0a),
            case asobi_lua_loader:call(init, [EncConfig], LuaSt1) of
                {ok, [GameState | _], LuaSt2} ->
                    {ok, #{lua_state => LuaSt2, game_state => GameState, script => ScriptPath}};
                {ok, [], _} ->
                    logger:error(#{
                        msg => ~"asobi_lua_world init: lua init() returned no value",
                        script => ScriptPath
                    }),
                    erlang:error({lua_error, ~"init() must return a table"});
                {error, Reason} ->
                    logger:error(#{
                        msg => ~"asobi_lua_world init: lua init() failed",
                        script => ScriptPath,
                        reason => Reason
                    }),
                    erlang:error({lua_init_failed, Reason})
            end;
        {error, Reason} ->
            logger:error(#{
                msg => ~"asobi_lua_world init: lua_loader:new/1 failed",
                script => ScriptPath,
                reason => Reason
            }),
            erlang:error({lua_load_failed, ScriptPath, Reason})
    end.

-spec join(binary(), map()) -> {ok, map()} | {error, term()}.
join(PlayerId, #{lua_state := LuaSt, game_state := GS} = State) ->
    case asobi_lua_loader:call(join, [PlayerId, GS], LuaSt) of
        {ok, [GS1 | _], LuaSt1} ->
            {ok, State#{lua_state => LuaSt1, game_state => GS1}};
        {error, Reason} ->
            {error, Reason}
    end.

-spec leave(binary(), map()) -> {ok, map()}.
leave(PlayerId, #{lua_state := LuaSt, game_state := GS} = State) ->
    case asobi_lua_loader:call(leave, [PlayerId, GS], LuaSt) of
        {ok, [GS1 | _], LuaSt1} ->
            {ok, State#{lua_state => LuaSt1, game_state => GS1}};
        {error, _} ->
            {ok, State}
    end.

-spec spawn_position(binary(), map()) -> {ok, {number(), number()}}.
spawn_position(PlayerId, #{lua_state := LuaSt, game_state := GS}) ->
    case asobi_lua_loader:call(spawn_position, [PlayerId, GS], LuaSt) of
        {ok, [PosTable | _], LuaSt1} ->
            Pos = decode_position(PosTable, LuaSt1),
            {ok, Pos};
        {error, _} ->
            {ok, {0.0, 0.0}}
    end.

-spec zone_tick(map(), term()) -> {map(), term()}.
zone_tick(Entities, ZoneState) when is_map(ZoneState), is_map_key(lua_state, ZoneState) ->
    LuaSt = maps:get(lua_state, ZoneState),
    {EncEntities, LuaSt1} = luerl:encode(Entities, LuaSt),
    GS = maps:get(game_state, ZoneState, nil),
    case asobi_lua_loader:call(zone_tick, [EncEntities, GS], LuaSt1, ?TICK_TIMEOUT) of
        {ok, [Ents1, ZS1 | _], LuaSt2} ->
            DecodedEnts = decode_to_map(Ents1, LuaSt2),
            {DecodedEnts, ZoneState#{lua_state => LuaSt2, game_state => ZS1}};
        {ok, [Ents1 | _], LuaSt2} ->
            DecodedEnts = decode_to_map(Ents1, LuaSt2),
            {DecodedEnts, ZoneState#{lua_state => LuaSt2}};
        {error, _} ->
            {Entities, ZoneState}
    end;
zone_tick(Entities, ZoneState) ->
    {Entities, ZoneState}.

-spec handle_input(binary(), map(), map()) -> {ok, map()} | {error, term()}.
handle_input(PlayerId, Input, Entities) when is_map(Entities), is_map_key(lua_state, Entities) ->
    LuaSt = maps:get(lua_state, Entities),
    {EncInput, LuaSt1} = luerl:encode(Input, LuaSt),
    {EncEntities, LuaSt2} = luerl:encode(maps:without([lua_state], Entities), LuaSt1),
    case asobi_lua_loader:call(handle_input, [PlayerId, EncInput, EncEntities], LuaSt2) of
        {ok, [Ents1 | _], LuaSt3} ->
            {ok, decode_to_map(Ents1, LuaSt3)};
        {error, _} ->
            {ok, Entities}
    end;
handle_input(_PlayerId, _Input, Entities) ->
    {ok, Entities}.

-spec post_tick(non_neg_integer(), map()) ->
    {ok, map()} | {vote, map(), map()} | {finished, map(), map()}.
post_tick(TickN, #{lua_state := LuaSt, game_state := GS} = State) ->
    case asobi_lua_loader:call(post_tick, [TickN, GS], LuaSt, ?TICK_TIMEOUT) of
        {ok, [GS1 | _], LuaSt1} ->
            State1 = State#{lua_state => LuaSt1, game_state => GS1},
            case check_post_tick_result(GS1, LuaSt1) of
                ok ->
                    {ok, State1};
                {vote, VoteConfig} ->
                    {vote, VoteConfig, State1};
                {finished, Result} ->
                    {finished, Result, State1}
            end;
        {error, timeout} ->
            logger:error(#{msg => ~"lua post_tick timeout", script => maps:get(script, State)}),
            {ok, State};
        {error, Reason} ->
            logger:error(#{msg => ~"lua post_tick error", reason => Reason}),
            {ok, State}
    end.

-spec generate_world(integer(), map()) -> {ok, map()}.
generate_world(Seed, #{lua_state := LuaSt} = _Config) ->
    case asobi_lua_loader:call(generate_world, [Seed, #{}], LuaSt) of
        {ok, [ZoneStates | _], LuaSt1} ->
            {ok, decode_zone_states(ZoneStates, LuaSt1)};
        {error, _} ->
            {ok, #{}}
    end.

-spec get_state(binary(), map()) -> map().
get_state(PlayerId, #{lua_state := LuaSt, game_state := GS}) ->
    case asobi_lua_loader:call(get_state, [PlayerId, GS], LuaSt) of
        {ok, [PlayerState | _], LuaSt1} ->
            decode_to_map(PlayerState, LuaSt1);
        {error, _} ->
            #{}
    end.

%% --- Phase callbacks ---

-spec phases(map()) -> [map()].
phases(#{lua_state := LuaSt} = _Config) ->
    case asobi_lua_loader:call(phases, [#{}], LuaSt) of
        {ok, [PhasesRef | _], LuaSt1} ->
            decode_phases(PhasesRef, LuaSt1);
        {error, _} ->
            []
    end;
phases(_) ->
    [].

-spec on_phase_started(binary(), map()) -> {ok, map()}.
on_phase_started(PhaseName, #{lua_state := LuaSt, game_state := GS} = State) ->
    case asobi_lua_loader:call(on_phase_started, [PhaseName, GS], LuaSt) of
        {ok, [GS1 | _], LuaSt1} ->
            {ok, State#{lua_state => LuaSt1, game_state => GS1}};
        {error, _} ->
            {ok, State}
    end.

-spec on_phase_ended(binary(), map()) -> {ok, map()}.
on_phase_ended(PhaseName, #{lua_state := LuaSt, game_state := GS} = State) ->
    case asobi_lua_loader:call(on_phase_ended, [PhaseName, GS], LuaSt) of
        {ok, [GS1 | _], LuaSt1} ->
            {ok, State#{lua_state => LuaSt1, game_state => GS1}};
        {error, _} ->
            {ok, State}
    end.

%% --- Spawn templates ---

-spec spawn_templates(map()) -> #{binary() => asobi_zone_spawner:spawn_template()}.
spawn_templates(#{lua_state := LuaSt} = _Config) ->
    case asobi_lua_loader:call(spawn_templates, [#{}], LuaSt) of
        {ok, [TemplatesRef | _], LuaSt1} ->
            decode_spawn_templates(TemplatesRef, LuaSt1);
        {error, _} ->
            #{}
    end;
spawn_templates(_) ->
    #{}.

%% --- World recovery ---

-spec on_world_recovered(map(), map()) -> {ok, map()}.
on_world_recovered(Snapshots, #{lua_state := LuaSt, game_state := GS} = State) ->
    {EncSnap, LuaSt1} = luerl:encode(Snapshots, LuaSt),
    case asobi_lua_loader:call(on_world_recovered, [EncSnap, GS], LuaSt1) of
        {ok, [GS1 | _], LuaSt2} ->
            {ok, State#{lua_state => LuaSt2, game_state => GS1}};
        {error, _} ->
            {ok, State}
    end.

%% --- Terrain & zone lifecycle ---

-spec terrain_provider(map()) -> {module(), map()} | none.
terrain_provider(#{lua_state := LuaSt} = _Config) ->
    case asobi_lua_loader:call(terrain_provider, [#{}], LuaSt) of
        {ok, [Result | _], LuaSt1} ->
            decode_terrain_provider(Result, LuaSt1);
        {error, _} ->
            none
    end;
terrain_provider(_) ->
    none.

-spec on_zone_loaded({integer(), integer()}, map()) -> {ok, map(), map()}.
on_zone_loaded({CX, CY}, #{lua_state := LuaSt, game_state := GS} = State) ->
    case asobi_lua_loader:call(on_zone_loaded, [CX, CY, GS], LuaSt) of
        {ok, [ZS, GS1 | _], LuaSt1} ->
            ZoneState = decode_to_map(ZS, LuaSt1),
            {ok, ZoneState, State#{lua_state => LuaSt1, game_state => GS1}};
        {ok, [ZS | _], LuaSt1} ->
            ZoneState = decode_to_map(ZS, LuaSt1),
            {ok, ZoneState, State#{lua_state => LuaSt1}};
        {error, _} ->
            {ok, #{}, State}
    end.

-spec on_zone_unloaded({integer(), integer()}, map()) -> {ok, map()}.
on_zone_unloaded({CX, CY}, #{lua_state := LuaSt, game_state := GS} = State) ->
    case asobi_lua_loader:call(on_zone_unloaded, [CX, CY, GS], LuaSt) of
        {ok, [GS1 | _], LuaSt1} ->
            {ok, State#{lua_state => LuaSt1, game_state => GS1}};
        {error, _} ->
            {ok, State}
    end.

%% --- Internal ---

decode_terrain_provider(Result, LuaSt) ->
    Decoded = luerl:decode(Result, LuaSt),
    case Decoded of
        nil ->
            none;
        false ->
            none;
        Props when is_list(Props) ->
            Module = proplists:get_value(~"module", Props),
            Args = proplists:get_value(~"args", Props, []),
            case Module of
                undefined ->
                    none;
                ModBin when is_binary(ModBin) ->
                    try
                        Mod = binary_to_existing_atom(ModBin),
                        DecodedArgs = deep_decode(Args),
                        ProvArgs =
                            case is_map(DecodedArgs) of
                                true -> DecodedArgs;
                                false -> #{}
                            end,
                        {Mod, ProvArgs}
                    catch
                        _:_ -> none
                    end;
                _ ->
                    none
            end;
        _ ->
            none
    end.

decode_position(PosTable, LuaSt) ->
    case luerl:decode(PosTable, LuaSt) of
        Decoded when is_list(Decoded) ->
            X = proplists:get_value(~"x", Decoded, 0.0),
            Y = proplists:get_value(~"y", Decoded, 0.0),
            {to_number(X), to_number(Y)};
        _ ->
            {0.0, 0.0}
    end.

check_post_tick_result(GS, LuaSt) ->
    try
        case luerl:get_table_key(GS, ~"_finished", LuaSt) of
            {ok, true, LuaSt1} ->
                case luerl:get_table_key(GS, ~"_result", LuaSt1) of
                    {ok, ResRef, LuaSt2} -> {finished, decode_to_map(ResRef, LuaSt2)};
                    _ -> {finished, #{}}
                end;
            _ ->
                case luerl:get_table_key(GS, ~"_vote", LuaSt) of
                    {ok, VoteRef, LuaSt1} when VoteRef =/= nil, VoteRef =/= false ->
                        {vote, decode_to_map(VoteRef, LuaSt1)};
                    _ ->
                        ok
                end
        end
    catch
        _:_ -> ok
    end.

decode_zone_states(ZoneStatesRef, LuaSt) ->
    case luerl:decode(ZoneStatesRef, LuaSt) of
        Decoded when is_list(Decoded) -> decode_zone_states_acc(Decoded, #{});
        _ -> #{}
    end.

-spec decode_zone_states_acc(list(), map()) -> map().
decode_zone_states_acc([], Acc) ->
    Acc;
decode_zone_states_acc([{Key, Val} | Rest], Acc) when is_binary(Key) ->
    case parse_coords(Key) of
        {ok, Coords} -> decode_zone_states_acc(Rest, Acc#{Coords => deep_decode(Val)});
        error -> decode_zone_states_acc(Rest, Acc)
    end;
decode_zone_states_acc([_ | Rest], Acc) ->
    decode_zone_states_acc(Rest, Acc).

decode_phases(PhasesRef, LuaSt) ->
    case luerl:decode(PhasesRef, LuaSt) of
        Decoded when is_list(Decoded) ->
            lists:filtermap(
                fun
                    ({_, PhaseProps}) when is_list(PhaseProps) ->
                        Name = proplists:get_value(~"name", PhaseProps),
                        case Name of
                            undefined ->
                                false;
                            _ ->
                                Phase0 = #{name => Name},
                                Phase1 = maybe_add(
                                    Phase0, duration, PhaseProps, ~"duration", fun to_integer/1
                                ),
                                Phase2 = maybe_add(
                                    Phase1, start, PhaseProps, ~"start", fun decode_phase_start/1
                                ),
                                Phase3 = maybe_add(
                                    Phase2, config, PhaseProps, ~"config", fun deep_decode/1
                                ),
                                {true, Phase3}
                        end;
                    (_) ->
                        false
                end,
                Decoded
            );
        _ ->
            []
    end.

decode_phase_start(~"prev_ended") ->
    prev_ended;
decode_phase_start(~"all_ready") ->
    all_ready;
decode_phase_start(V) when is_number(V) -> {timer, trunc(V)};
decode_phase_start(Props) when is_list(Props) ->
    case proplists:get_value(~"players", Props) of
        N when is_number(N) -> {players, trunc(N)};
        _ ->
            case proplists:get_value(~"timer", Props) of
                N when is_number(N) -> {timer, trunc(N)};
                _ -> prev_ended
            end
    end;
decode_phase_start(_) ->
    prev_ended.

maybe_add(Map, Key, Props, LuaKey, DecodeFn) ->
    case proplists:get_value(LuaKey, Props) of
        undefined -> Map;
        nil -> Map;
        Val -> Map#{Key => DecodeFn(Val)}
    end.

parse_coords(Bin) ->
    case binary:split(Bin, ~",") of
        [XBin, YBin] ->
            try
                X = binary_to_integer(XBin),
                Y = binary_to_integer(YBin),
                {ok, {X, Y}}
            catch
                _:_ -> error
            end;
        _ ->
            error
    end.

decode_to_map(Term, LuaSt) ->
    deep_decode(luerl:decode(Term, LuaSt)).

deep_decode([{K, _} | _] = PropList) when is_binary(K) ->
    maps:from_list(deep_decode_pairs(PropList));
deep_decode([{N, _} | _] = NumList) when is_integer(N) ->
    [deep_decode(Val) || {_, Val} <- lists:sort(NumList)];
deep_decode(M) when is_map(M) ->
    maps:map(fun(_, V) -> deep_decode(V) end, M);
deep_decode(L) when is_list(L) ->
    [deep_decode(E) || E <- L];
deep_decode(V) ->
    V.

deep_decode_pairs([{Key, Val} | Rest]) ->
    [{Key, deep_decode(Val)} | deep_decode_pairs(Rest)];
deep_decode_pairs([]) ->
    [].

to_number(N) when is_number(N) -> N;
to_number(_) -> 0.0.

to_integer(N) when is_number(N) -> trunc(N);
to_integer(_) -> 0.

decode_spawn_templates(TemplatesRef, LuaSt) ->
    case luerl:decode(TemplatesRef, LuaSt) of
        Decoded when is_list(Decoded) -> decode_spawn_templates_acc(Decoded, #{});
        _ -> #{}
    end.

-spec decode_spawn_templates_acc(list(), map()) -> map().
decode_spawn_templates_acc([], Acc) ->
    Acc;
decode_spawn_templates_acc([{TemplateId, Props} | Rest], Acc) when
    is_binary(TemplateId), is_list(Props)
->
    Type = proplists:get_value(~"type", Props, ~"npc"),
    BaseState = deep_decode(proplists:get_value(~"base_state", Props, [])),
    Base =
        case is_map(BaseState) of
            true -> BaseState;
            false -> #{}
        end,
    Template = #{
        template_id => TemplateId,
        type => Type,
        base_state => Base,
        persistent => proplists:get_value(~"persistent", Props, true),
        respawn => decode_respawn_rule(proplists:get_value(~"respawn", Props, nil))
    },
    decode_spawn_templates_acc(Rest, Acc#{TemplateId => Template});
decode_spawn_templates_acc([_ | Rest], Acc) ->
    decode_spawn_templates_acc(Rest, Acc).

decode_respawn_rule(nil) ->
    undefined;
decode_respawn_rule(false) ->
    undefined;
decode_respawn_rule(Props) when is_list(Props) ->
    #{
        strategy => timer,
        delay => to_integer(proplists:get_value(~"delay", Props, 0)),
        max_respawns => decode_max_respawns(
            proplists:get_value(~"max_respawns", Props, nil)
        ),
        jitter => to_integer(proplists:get_value(~"jitter", Props, 0))
    };
decode_respawn_rule(_) ->
    undefined.

decode_max_respawns(nil) -> infinity;
decode_max_respawns(N) when is_number(N) -> trunc(N);
decode_max_respawns(_) -> infinity.
