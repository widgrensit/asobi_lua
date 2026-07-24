-module(asobi_lua_world).
-moduledoc """
An `asobi_world` implementation that delegates all callbacks to Lua scripts
via Luerl.

The Lua script must define these functions:

```lua
function init(config)                        -- return initial game state
function join(player_id, state, ctx)         -- ctx is the client join context
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

-include_lib("kernel/include/logger.hrl").

-export([init/1, join/2, join/3, leave/2, spawn_position/2]).
-export([zone_tick/2, handle_input/3, post_tick/2]).
-export([generate_world/2, get_state/2]).
-export([phases/1, on_phase_started/2, on_phase_ended/2]).
-export([spawn_templates/1, on_world_recovered/2]).
-export([terrain_provider/1, on_zone_loaded/2, on_zone_unloaded/2]).
-export([init_zone_state/2, dump_zone_state/1]).

%% Wall-clock budgets for Lua callbacks. Init-time callbacks
%% (`init`, `generate_world`, `phases`, `spawn_templates`,
%% `terrain_provider`) get more headroom because building a world or a
%% phase table can be CPU-heavy. Per-tick callbacks share the tighter
%% TICK_TIMEOUT so a runaway script can't wedge the zone loop.
-define(INIT_TIMEOUT, 2000).
-define(GENERATE_TIMEOUT, 5000).
-define(TICK_TIMEOUT, 500).
-define(JOIN_TIMEOUT, 200).
-define(LEAVE_TIMEOUT, 200).
-define(GET_STATE_TIMEOUT, 100).
-define(SPAWN_POS_TIMEOUT, 100).
-define(PHASE_TIMEOUT, 200).
-define(ZONE_LIFECYCLE_TIMEOUT, 200).

-spec init(map()) -> {ok, map()}.
init(Config) ->
    ScriptPath =
        case maps:get(lua_script, Config, undefined) of
            P when is_binary(P); is_list(P) ->
                P;
            undefined ->
                ?LOG_ERROR(#{msg => ~"asobi_lua_world init: missing lua_script", config => Config}),
                erlang:error({missing_lua_script, Config})
        end,
    GameConfig = maps:get(game_config, Config, #{}),
    PreInstall = fun(St) -> asobi_lua_api:install(make_ctx(Config), St) end,
    case asobi_lua_loader:new(ScriptPath, ?INIT_TIMEOUT, PreInstall) of
        {ok, LuaSt0} ->
            {EncConfig, LuaSt1} = luerl:encode(GameConfig, LuaSt0),
            case asobi_lua_loader:call(init, [EncConfig], LuaSt1, ?INIT_TIMEOUT) of
                {ok, [GameState | _], LuaSt2} ->
                    {ok, #{
                        lua_state => LuaSt2,
                        game_state => GameState,
                        script => ScriptPath,
                        script_mtime => filelib:last_modified(ScriptPath)
                    }};
                {ok, [], _} ->
                    ?LOG_ERROR(#{
                        msg => ~"asobi_lua_world init: lua init() returned no value",
                        script => ScriptPath
                    }),
                    erlang:error({lua_error, ~"init() must return a table"});
                {error, Reason} ->
                    ?LOG_ERROR(#{
                        msg => ~"asobi_lua_world init: lua init() failed",
                        script => ScriptPath,
                        reason => Reason
                    }),
                    erlang:error({lua_init_failed, Reason})
            end;
        {error, Reason} ->
            ?LOG_ERROR(#{
                msg => ~"asobi_lua_world init: lua_loader:new/1 failed",
                script => ScriptPath,
                reason => Reason
            }),
            erlang:error({lua_load_failed, ScriptPath, Reason})
    end.

-spec join(binary(), map()) -> {ok, map()} | {error, term()}.
join(PlayerId, State) ->
    join(PlayerId, #{}, State).

-doc """
Join carrying the client-supplied join context (asobi's optional `join/3`).

Passed to the Lua `join` as a third argument: `function join(player_id,
state)` keeps working (Lua discards extra arguments) and
`function join(player_id, state, ctx)` receives it.
""".
-spec join(binary(), map(), map()) -> {ok, map()} | {error, term()}.
join(PlayerId, Ctx, #{lua_state := LuaSt, game_state := GS} = State) when is_map(Ctx) ->
    %% Erlang maps must be encoded before they cross into Luerl - GS is
    %% already a Lua value, but Ctx arrives raw from the client.
    {EncCtx, LuaSt0} = luerl:encode(Ctx, LuaSt),
    case asobi_lua_loader:call(join, [PlayerId, GS, EncCtx], LuaSt0, ?JOIN_TIMEOUT) of
        {ok, [GS1 | _], LuaSt1} ->
            {ok, State#{lua_state => LuaSt1, game_state => GS1}};
        {error, Reason} ->
            {error, Reason}
    end.

-spec leave(binary(), map()) -> {ok, map()}.
leave(PlayerId, #{lua_state := LuaSt, game_state := GS} = State) ->
    case asobi_lua_loader:call(leave, [PlayerId, GS], LuaSt, ?LEAVE_TIMEOUT) of
        {ok, [GS1 | _], LuaSt1} ->
            {ok, State#{lua_state => LuaSt1, game_state => GS1}};
        {error, Reason} ->
            log_lua_error(leave, Reason, State),
            {ok, State}
    end.

-spec spawn_position(binary(), map()) -> {ok, {number(), number()}}.
spawn_position(PlayerId, #{lua_state := LuaSt, game_state := GS} = State) ->
    case asobi_lua_loader:call(spawn_position, [PlayerId, GS], LuaSt, ?SPAWN_POS_TIMEOUT) of
        {ok, [PosTable | _], LuaSt1} ->
            Pos = decode_position(PosTable, LuaSt1),
            {ok, Pos};
        {error, Reason} ->
            log_lua_error(spawn_position, Reason, State),
            {ok, {0.0, 0.0}}
    end.

%% asobi_zone calls apply_inputs (handle_input/3) *before* zone_tick/2 each
%% tick, and the only state it carries is the entities map — no lua_state
%% threaded through. We bridge that by stashing the current ZoneState in the
%% zone process's dictionary from zone_tick, and reading it back in
%% handle_input. Both run inside the same zone gen_server process so the
%% proc dict is safe and per-zone-isolated.
-define(PD_KEY, {?MODULE, zone_state}).

-spec zone_tick(map(), term()) -> {map(), term()}.
zone_tick(Entities, ZoneState0) when is_map(ZoneState0) ->
    %% Pick up any lua_state updates that handle_input stashed earlier this tick.
    ZoneState1 =
        case erlang:get(?PD_KEY) of
            #{lua_state := LuaFromDict} -> ZoneState0#{lua_state => LuaFromDict};
            _ -> ZoneState0
        end,
    %% Hot-reload the script if it changed on disk since the last tick.
    %% Mirrors asobi_lua_match's per-tick reload — keeps live worlds in sync
    %% with on-disk edits without restarting the zone process.
    ZoneState = asobi_lua_reload:maybe_hot_reload(ZoneState1),
    Result =
        case maps:get(lua_state, ZoneState, undefined) of
            undefined ->
                {Entities, ZoneState};
            LuaSt ->
                {EncEntities, LuaSt1} = luerl:encode(Entities, LuaSt),
                GS = maps:get(game_state, ZoneState, nil),
                case
                    asobi_lua_loader:call(
                        zone_tick, [EncEntities, GS], LuaSt1, ?TICK_TIMEOUT
                    )
                of
                    {ok, [Ents1, ZS1 | _], LuaSt2} ->
                        {decode_to_map(Ents1, LuaSt2), ZoneState#{
                            lua_state => LuaSt2, game_state => ZS1
                        }};
                    {ok, [Ents1 | _], LuaSt2} ->
                        {decode_to_map(Ents1, LuaSt2), ZoneState#{lua_state => LuaSt2}};
                    {error, Reason} ->
                        log_lua_error(zone_tick, Reason, ZoneState),
                        {Entities, ZoneState}
                end
        end,
    {_, NewZoneState} = Result,
    erlang:put(?PD_KEY, NewZoneState),
    Result;
zone_tick(Entities, ZoneState) ->
    {Entities, ZoneState}.

-spec handle_input(binary(), map(), map()) -> {ok, map()} | {error, term()}.
handle_input(PlayerId, Input, Entities) ->
    case erlang:get(?PD_KEY) of
        #{lua_state := LuaSt} = ZoneState ->
            {EncInput, LuaSt1} = luerl:encode(Input, LuaSt),
            {EncEntities, LuaSt2} = luerl:encode(Entities, LuaSt1),
            %% No bounded_eval: see ADR 0002.
            case
                asobi_lua_loader:call(
                    handle_input, [PlayerId, EncInput, EncEntities], LuaSt2
                )
            of
                {ok, [Ents1 | _], LuaSt3} ->
                    erlang:put(?PD_KEY, ZoneState#{lua_state => LuaSt3}),
                    {ok, decode_to_map(Ents1, LuaSt3)};
                {error, Reason} ->
                    log_lua_error(handle_input, Reason, ZoneState),
                    {ok, Entities}
            end;
        _ ->
            {ok, Entities}
    end.

-spec post_tick(non_neg_integer(), map()) ->
    {ok, map()} | {vote, map(), map()} | {finished, map(), map()}.
post_tick(TickN, State0) ->
    %% Hot-reload the world-level script (separate from per-zone reload in
    %% zone_tick). Reloading at world level keeps phases, post_tick, and
    %% on_phase_* callbacks in sync with on-disk edits.
    #{lua_state := LuaSt, game_state := GS} = State = asobi_lua_reload:maybe_hot_reload(State0),
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
        {error, Reason} ->
            log_lua_error(post_tick, Reason, State),
            {ok, State}
    end.

-spec generate_world(integer(), map()) -> {ok, map()}.
generate_world(Seed, #{lua_state := LuaSt} = _Config) ->
    case asobi_lua_loader:call(generate_world, [Seed, #{}], LuaSt, ?GENERATE_TIMEOUT) of
        {ok, [ZoneStates | _], LuaSt1} ->
            {ok, decode_zone_states(ZoneStates, LuaSt1)};
        {error, _} ->
            {ok, #{}}
    end;
generate_world(Seed, Config) when is_map(Config) ->
    %% Called by asobi_world_server before init/1 has run, so no lua_state is
    %% threaded through. Build a fresh luerl state to ask the script for zone
    %% coords, then give each returned zone its own luerl state so subsequent
    %% zone_tick/handle_input calls can invoke Lua callbacks.
    GameConfig = maps:get(game_config, Config, #{}),
    case maps:get(lua_script, GameConfig, undefined) of
        undefined ->
            {ok, #{}};
        ScriptPath ->
            %% match_pid in the ctx is the caller of generate_world/2 — typically
            %% asobi_world_server, not a match process. game.broadcast emitted
            %% from a script's generate_world callback therefore reaches the
            %% world server, mirroring how broadcast already routed pre-fix.
            PreInstall = fun(St) -> asobi_lua_api:install(make_ctx(Config), St) end,
            case asobi_lua_loader:new(ScriptPath, ?GENERATE_TIMEOUT, PreInstall) of
                {ok, LuaSt} ->
                    %% Only used to ask the script for zone coords + initial
                    %% per-zone state. Each zone builds its own VM later, in its
                    %% own process, via init_zone_state/2.
                    generate_world(Seed, #{lua_state => LuaSt});
                {error, Reason} ->
                    ?LOG_ERROR(#{
                        msg =>
                            ~"asobi_lua_world generate_world: lua_loader:new failed; world will spawn with empty zones",
                        script => ScriptPath,
                        reason => Reason
                    }),
                    {ok, #{}}
            end
    end.

-spec get_state(binary(), map()) -> map().
get_state(PlayerId, #{lua_state := LuaSt, game_state := GS}) ->
    case asobi_lua_loader:call(get_state, [PlayerId, GS], LuaSt, ?GET_STATE_TIMEOUT) of
        {ok, [PlayerState | _], LuaSt1} ->
            decode_to_map(PlayerState, LuaSt1);
        {error, _} ->
            #{}
    end.

%% --- Phase callbacks ---

-spec phases(map()) -> [map()].
phases(#{lua_state := LuaSt} = _Config) ->
    case asobi_lua_loader:call(phases, [#{}], LuaSt, ?INIT_TIMEOUT) of
        {ok, [PhasesRef | _], LuaSt1} ->
            decode_phases(PhasesRef, LuaSt1);
        {error, _} ->
            []
    end;
phases(_) ->
    [].

-spec on_phase_started(binary(), map()) -> {ok, map()}.
on_phase_started(PhaseName, #{lua_state := LuaSt, game_state := GS} = State) ->
    case asobi_lua_loader:call(on_phase_started, [PhaseName, GS], LuaSt, ?PHASE_TIMEOUT) of
        {ok, [GS1 | _], LuaSt1} ->
            {ok, State#{lua_state => LuaSt1, game_state => GS1}};
        {error, _} ->
            {ok, State}
    end.

-spec on_phase_ended(binary(), map()) -> {ok, map()}.
on_phase_ended(PhaseName, #{lua_state := LuaSt, game_state := GS} = State) ->
    case asobi_lua_loader:call(on_phase_ended, [PhaseName, GS], LuaSt, ?PHASE_TIMEOUT) of
        {ok, [GS1 | _], LuaSt1} ->
            {ok, State#{lua_state => LuaSt1, game_state => GS1}};
        {error, _} ->
            {ok, State}
    end.

%% --- Spawn templates ---

-spec spawn_templates(map()) -> #{binary() => asobi_zone_spawner:spawn_template()}.
spawn_templates(#{lua_state := LuaSt} = _Config) ->
    case asobi_lua_loader:call(spawn_templates, [#{}], LuaSt, ?INIT_TIMEOUT) of
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
    case asobi_lua_loader:call(on_world_recovered, [EncSnap, GS], LuaSt1, ?INIT_TIMEOUT) of
        {ok, [GS1 | _], LuaSt2} ->
            {ok, State#{lua_state => LuaSt2, game_state => GS1}};
        {error, _} ->
            {ok, State}
    end.

%% --- Terrain & zone lifecycle ---

-spec terrain_provider(map()) -> {module(), map()} | none.
terrain_provider(#{lua_state := LuaSt} = _Config) ->
    case asobi_lua_loader:call(terrain_provider, [#{}], LuaSt, ?INIT_TIMEOUT) of
        {ok, [Result | _], LuaSt1} ->
            decode_terrain_provider(Result, LuaSt1);
        {error, _} ->
            none
    end;
terrain_provider(_) ->
    none.

-spec on_zone_loaded({integer(), integer()}, map()) -> {ok, map(), map()}.
on_zone_loaded({CX, CY}, #{lua_state := LuaSt, game_state := GS} = State) ->
    case asobi_lua_loader:call(on_zone_loaded, [CX, CY, GS], LuaSt, ?ZONE_LIFECYCLE_TIMEOUT) of
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
    case asobi_lua_loader:call(on_zone_unloaded, [CX, CY, GS], LuaSt, ?ZONE_LIFECYCLE_TIMEOUT) of
        {ok, [GS1 | _], LuaSt1} ->
            {ok, State#{lua_state => LuaSt1, game_state => GS1}};
        {error, _} ->
            {ok, State}
    end.

%% --- Internal ---

%% H-2: a Lua script can return any binary as `module`. Without an
%% allowlist, the bridge would `binary_to_existing_atom` and call
%% `Mod:init/1`, `Mod:load_chunk/2`, `Mod:generate_chunk/3` on whichever
%% loaded module the script names — including unrelated OTP modules
%% (`gen_server`, `rpc`, `application`, etc.). Treat the set of valid
%% terrain providers as a small explicit list, configurable via env so
%% operators shipping new providers can extend it without code changes.
-define(DEFAULT_TERRAIN_PROVIDERS, [
    asobi_terrain_flat,
    asobi_terrain_perlin
]).

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
                    case lookup_allowed_provider(ModBin) of
                        {ok, Mod} ->
                            DecodedArgs = deep_decode(Args),
                            ProvArgs =
                                case is_map(DecodedArgs) of
                                    true -> DecodedArgs;
                                    false -> #{}
                                end,
                            {Mod, ProvArgs};
                        not_allowed ->
                            ?LOG_WARNING(#{
                                msg => ~"terrain_provider_not_allowed",
                                requested => ModBin
                            }),
                            none
                    end;
                _ ->
                    none
            end;
        _ ->
            none
    end.

-spec lookup_allowed_provider(binary()) -> {ok, atom()} | not_allowed.
lookup_allowed_provider(ModBin) ->
    Allowed = allowed_terrain_providers(),
    AllowedBins = [atom_to_binary(M, utf8) || M <- Allowed],
    case lists:member(ModBin, AllowedBins) of
        true ->
            try
                {ok, binary_to_existing_atom(ModBin, utf8)}
            catch
                _:_ -> not_allowed
            end;
        false ->
            not_allowed
    end.

-spec allowed_terrain_providers() -> [atom()].
allowed_terrain_providers() ->
    case application:get_env(asobi_lua, terrain_providers, ?DEFAULT_TERRAIN_PROVIDERS) of
        L when is_list(L) -> [M || M <- L, is_atom(M)];
        _ -> ?DEFAULT_TERRAIN_PROVIDERS
    end.

%% Logs Lua callback failures uniformly. Pre-fix, leave/spawn_position/
%% zone_tick/handle_input swallowed errors silently and only post_tick logged
%% — so a broken Lua script could degrade gameplay invisibly. State is either
%% the world State (carries `script`) or a per-zone ZoneState (may not).
log_lua_error(Callback, Reason, StateOrZoneState) ->
    Script = maps:get(script, StateOrZoneState, ~"<unknown>"),
    Severity =
        case Reason of
            timeout -> ~"timeout";
            _ -> ~"error"
        end,
    ?LOG_WARNING(#{
        msg => ~"lua callback failed",
        callback => Callback,
        severity => Severity,
        script => Script,
        reason => Reason
    }),
    %% Public game-error signal; only bounded PII-free context crosses it (the
    %% raw Reason stays in the local log above).
    asobi_lua_game_error:emit(Callback, Reason, Script).

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
        Other ->
            %% Lua phases() returned a non-list — likely a script bug. Logging the
            %% type helps the developer notice it; without this, decode silently
            %% returned [], the world server treated it as "no phases", and the
            %% mismatch only surfaced as runtime weirdness much later.
            ?LOG_WARNING(#{
                msg => ~"asobi_lua_world: phases() returned non-list, ignoring",
                got_type => type_of(Other)
            }),
            []
    end.

type_of(V) when is_list(V) -> ~"list";
type_of(V) when is_map(V) -> ~"map";
type_of(V) when is_binary(V) -> ~"binary";
type_of(V) when is_integer(V) -> ~"integer";
type_of(V) when is_float(V) -> ~"float";
type_of(V) when is_atom(V) -> ~"atom";
type_of(V) when is_tuple(V) -> ~"tuple";
type_of(_) -> ~"unknown".

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
    asobi_lua_api:decode_to_map(Term, LuaSt).

deep_decode(Term) ->
    asobi_lua_api:deep_decode(Term).

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

%% Build this zone's Luerl VM in the zone process, so it binds to the zone pid
%% (self()) and game.zone.spawn / zone-based game.spatial / game.terrain resolve.
%% Called once via asobi_zone's handle_continue, for every zone-creation path
%% (pre-spawned, lazy, recovered). Re-encodes gameplay state from a prior
%% snapshot if present; the VM itself is never persisted, only rebuilt here.
-spec init_zone_state(map(), term()) -> map().
init_zone_state(Config, ZoneState00) ->
    %% An empty Lua zone table decodes to [], not #{}; coerce before merging.
    ZoneState0 =
        case ZoneState00 of
            M when is_map(M) -> M;
            _ -> #{}
        end,
    GameConfig = maps:get(game_config, Config, #{}),
    case maps:get(lua_script, GameConfig, undefined) of
        undefined ->
            ZoneState0;
        ScriptPath ->
            PreInstall = fun(St) -> asobi_lua_api:install(zone_ctx(Config), St) end,
            case asobi_lua_loader:new(ScriptPath, ?GENERATE_TIMEOUT, PreInstall) of
                {ok, LuaSt0} ->
                    {GameState, LuaSt1} = restore_game_state(ZoneState0, LuaSt0),
                    ZoneState0#{
                        lua_state => LuaSt1,
                        game_state => GameState,
                        script => ScriptPath,
                        script_mtime => filelib:last_modified(ScriptPath)
                    };
                {error, Reason} ->
                    ?LOG_ERROR(#{
                        msg =>
                            ~"asobi_lua_world init_zone_state: lua_loader:new failed; zone Lua inert",
                        script => ScriptPath,
                        reason => Reason
                    }),
                    ZoneState0
            end
    end.

%% Inverse of init_zone_state's restore path: drop the non-serialisable VM and
%% decode the script's gameplay state to a plain, JSON-safe map for jsonb.
%% game_state is the sole canonical persisted field; other per-zone keys are
%% rebuilt from config on init, so they are intentionally not carried here.
%% A never-seeded zone (game_state nil) round-trips as null, not #{}, so the
%% script's `game_state == nil` initialisation guard still fires after recovery.
-spec dump_zone_state(map()) -> map().
dump_zone_state(#{lua_state := LuaSt} = ZoneState) ->
    GameState =
        case maps:get(game_state, ZoneState, nil) of
            nil -> null;
            GS -> decode_to_map(GS, LuaSt)
        end,
    #{~"game_state" => GameState};
dump_zone_state(ZoneState) ->
    maps:remove(lua_state, ZoneState).

-spec restore_game_state(map(), dynamic()) -> {dynamic(), dynamic()}.
restore_game_state(ZoneState0, LuaSt) ->
    case maps:get(~"game_state", ZoneState0, undefined) of
        Map when is_map(Map) -> luerl:encode(Map, LuaSt);
        _ -> {nil, LuaSt}
    end.

-spec zone_ctx(map()) -> map().
zone_ctx(Config) ->
    GameConfig = maps:get(game_config, Config, #{}),
    #{
        zone_pid => self(),
        match_pid => maps:get(world_server_pid, Config, self()),
        match_id => maps:get(match_id, GameConfig, maps:get(world_id, Config, undefined))
    }.

-spec make_ctx(map()) -> map().
make_ctx(Config) ->
    #{
        match_id => maps:get(match_id, Config, undefined),
        match_pid => self()
    }.
