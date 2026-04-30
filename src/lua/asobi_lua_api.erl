-module(asobi_lua_api).
-moduledoc """
Installs the `game.*` Lua API into a Luerl state, giving Lua scripts
access to engine features like economy, leaderboards, notifications,
storage, messaging, spatial queries, and zone spawning.

Called from `asobi_lua_match:init/1` and `asobi_lua_world:init/1`
before the Lua script's `init()` runs.

## Available API

```lua
-- IDs
game.id()                                        -- generate UUIDv7

-- Messaging
game.broadcast(event, payload)                   -- broadcast to all match players
game.send(player_id, message)                    -- send to specific player

-- Economy
game.economy.grant(player_id, currency, amount, reason)
game.economy.debit(player_id, currency, amount, reason)
game.economy.balance(player_id)
game.economy.purchase(player_id, listing_id)

-- Leaderboards
game.leaderboard.submit(board_id, player_id, score)
game.leaderboard.top(board_id, count)
game.leaderboard.rank(board_id, player_id)
game.leaderboard.around(board_id, player_id, count)

-- Notifications
game.notify(player_id, type, subject, data)
game.notify_many(player_ids, type, subject, data)

-- Key-Value Storage
game.storage.get(collection, key)
game.storage.set(collection, key, value)
game.storage.player_get(player_id, collection, key)
game.storage.player_set(player_id, collection, key, value)

-- Chat
game.chat.send(channel_id, sender_id, content)

-- Spatial queries (operate on entity tables)
game.spatial.query_radius(entities, x, y, radius)
game.spatial.query_radius(entities, x, y, radius, opts)
game.spatial.query_radius(x, y, radius)              -- zone-based (requires zone_pid)
game.spatial.query_rect(x1, y1, x2, y2)              -- zone-based (requires zone_pid)
game.spatial.nearest(entities, x, y, n)
game.spatial.nearest(entities, x, y, n, opts)
game.spatial.in_range(entity_a, entity_b, range)
game.spatial.distance(entity_a, entity_b)

-- Zone spawning (world mode only, requires zone_pid in context)
game.zone.spawn(template_id, x, y)
game.zone.spawn(template_id, x, y, overrides)
game.zone.despawn(entity_id)

-- Terrain (world mode only, requires terrain_store_pid in context)
game.terrain.get_chunk(cx, cy)                   -- get compressed chunk data
game.terrain.preload(coords_list)                -- preload chunks async
```
""".

-export([install/2]).
-export([deep_decode/1, decode_to_map/2]).

-spec install(map(), dynamic()) -> dynamic().
install(Ctx, St0) ->
    %% Pre-create namespace tables
    St1 = create_table([~"game"], St0),
    St2 = create_table([~"game", ~"economy"], St1),
    St3 = create_table([~"game", ~"leaderboard"], St2),
    St4 = create_table([~"game", ~"storage"], St3),
    St5a = create_table([~"game", ~"chat"], St4),
    St5b = create_table([~"game", ~"spatial"], St5a),
    St5c = create_table([~"game", ~"zone"], St5b),
    St5 = create_table([~"game", ~"terrain"], St5c),
    Fns = [
        %% Core
        {[~"game", ~"id"], fun_id()},
        {[~"game", ~"broadcast"], fun_broadcast(Ctx)},
        {[~"game", ~"send"], fun_send()},
        %% Economy
        {[~"game", ~"economy", ~"grant"], fun_economy_grant()},
        {[~"game", ~"economy", ~"debit"], fun_economy_debit()},
        {[~"game", ~"economy", ~"balance"], fun_economy_balance()},
        {[~"game", ~"economy", ~"purchase"], fun_economy_purchase()},
        %% Leaderboard
        {[~"game", ~"leaderboard", ~"submit"], fun_lb_submit()},
        {[~"game", ~"leaderboard", ~"top"], fun_lb_top()},
        {[~"game", ~"leaderboard", ~"rank"], fun_lb_rank()},
        {[~"game", ~"leaderboard", ~"around"], fun_lb_around()},
        %% Notifications
        {[~"game", ~"notify"], fun_notify()},
        {[~"game", ~"notify_many"], fun_notify_many()},
        %% Storage
        {[~"game", ~"storage", ~"get"], fun_storage_get()},
        {[~"game", ~"storage", ~"set"], fun_storage_set()},
        {[~"game", ~"storage", ~"player_get"], fun_storage_player_get()},
        {[~"game", ~"storage", ~"player_set"], fun_storage_player_set()},
        %% Chat
        {[~"game", ~"chat", ~"send"], fun_chat_send()},
        %% Spatial
        {[~"game", ~"spatial", ~"query_radius"], fun_spatial_query_radius(Ctx)},
        {[~"game", ~"spatial", ~"query_rect"], fun_spatial_query_rect(Ctx)},
        {[~"game", ~"spatial", ~"nearest"], fun_spatial_nearest()},
        {[~"game", ~"spatial", ~"in_range"], fun_spatial_in_range()},
        {[~"game", ~"spatial", ~"distance"], fun_spatial_distance()},
        %% Zone spawning
        {[~"game", ~"zone", ~"spawn"], fun_zone_spawn(Ctx)},
        {[~"game", ~"zone", ~"despawn"], fun_zone_despawn(Ctx)},
        %% Terrain
        {[~"game", ~"terrain", ~"get_chunk"], fun_terrain_get_chunk(Ctx)},
        {[~"game", ~"terrain", ~"preload"], fun_terrain_preload(Ctx)}
    ],
    lists:foldl(
        fun({Path, Fn}, St) ->
            {Enc, StA} = luerl:encode(Fn, St),
            {ok, StB} = luerl:set_table_keys(Path, Enc, StA),
            StB
        end,
        St5,
        Fns
    ).

%% --- Core ---

fun_id() ->
    fun(_, St) ->
        Id = asobi_id:generate(),
        {[Id], St}
    end.

fun_broadcast(#{match_pid := MatchPid}) ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [Event, Payload] when is_binary(Event) ->
                asobi_match_server:broadcast_event(MatchPid, Event, to_map(Payload)),
                {[true], St};
            [Event] when is_binary(Event) ->
                asobi_match_server:broadcast_event(MatchPid, Event, #{}),
                {[true], St};
            _ ->
                error_result(~"broadcast requires (event, payload)", St)
        end
    end;
fun_broadcast(_) ->
    fun(_, St) -> error_result(~"broadcast not available (no match context)", St) end.

fun_send() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [PlayerId, Message] when is_binary(PlayerId) ->
                asobi_presence:send(PlayerId, {game_message, to_map(Message)}),
                {[true], St};
            _ ->
                error_result(~"send requires (player_id, message)", St)
        end
    end.

%% --- Economy ---

fun_economy_grant() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [PlayerId, Currency, Amount, Reason] when
                is_binary(PlayerId),
                is_binary(Currency),
                is_number(Amount),
                is_binary(Reason)
            ->
                wrap_result(
                    asobi_economy:grant(PlayerId, Currency, trunc(Amount), #{reason => Reason}),
                    St
                );
            [PlayerId, Currency, Amount] when
                is_binary(PlayerId), is_binary(Currency), is_number(Amount)
            ->
                wrap_result(
                    asobi_economy:grant(PlayerId, Currency, trunc(Amount), #{}),
                    St
                );
            _ ->
                error_result(~"grant requires (player_id, currency, amount[, reason])", St)
        end
    end.

fun_economy_debit() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [PlayerId, Currency, Amount, Reason] when
                is_binary(PlayerId),
                is_binary(Currency),
                is_number(Amount),
                is_binary(Reason)
            ->
                wrap_result(
                    asobi_economy:debit(PlayerId, Currency, trunc(Amount), #{reason => Reason}),
                    St
                );
            [PlayerId, Currency, Amount] when
                is_binary(PlayerId), is_binary(Currency), is_number(Amount)
            ->
                wrap_result(
                    asobi_economy:debit(PlayerId, Currency, trunc(Amount), #{}),
                    St
                );
            _ ->
                error_result(~"debit requires (player_id, currency, amount[, reason])", St)
        end
    end.

fun_economy_balance() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [PlayerId] when is_binary(PlayerId) ->
                case asobi_economy:get_wallets(PlayerId) of
                    {ok, Wallets} ->
                        Sanitized = [
                            #{
                                ~"currency" => maps:get(currency, W, ~""),
                                ~"balance" => maps:get(balance, W, 0)
                            }
                         || W <- Wallets
                        ],
                        ok_result(Sanitized, St);
                    {error, Reason} ->
                        error_result(Reason, St)
                end;
            _ ->
                error_result(~"balance requires (player_id)", St)
        end
    end.

fun_economy_purchase() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [PlayerId, ListingId] when is_binary(PlayerId), is_binary(ListingId) ->
                wrap_result(asobi_economy:purchase(PlayerId, ListingId), St);
            _ ->
                error_result(~"purchase requires (player_id, listing_id)", St)
        end
    end.

%% --- Leaderboard ---

fun_lb_submit() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [BoardId, PlayerId, Score] when
                is_binary(BoardId), is_binary(PlayerId), is_number(Score)
            ->
                asobi_leaderboard_server:submit(BoardId, PlayerId, trunc(Score)),
                {[true], St};
            _ ->
                error_result(~"submit requires (board_id, player_id, score)", St)
        end
    end.

fun_lb_top() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [BoardId, Count] when is_binary(BoardId), is_number(Count) ->
                Entries = asobi_leaderboard_server:top(BoardId, trunc(Count)),
                Encoded = encode_lb_entries(Entries),
                ok_result(Encoded, St);
            _ ->
                error_result(~"top requires (board_id, count)", St)
        end
    end.

fun_lb_rank() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [BoardId, PlayerId] when is_binary(BoardId), is_binary(PlayerId) ->
                case asobi_leaderboard_server:rank(BoardId, PlayerId) of
                    {ok, Rank} -> ok_result(Rank, St);
                    {error, not_found} -> error_result(~"not_found", St)
                end;
            _ ->
                error_result(~"rank requires (board_id, player_id)", St)
        end
    end.

fun_lb_around() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [BoardId, PlayerId, Count] when
                is_binary(BoardId), is_binary(PlayerId), is_number(Count)
            ->
                Entries = asobi_leaderboard_server:around(BoardId, PlayerId, trunc(Count)),
                Encoded = encode_lb_entries(Entries),
                ok_result(Encoded, St);
            _ ->
                error_result(~"around requires (board_id, player_id, count)", St)
        end
    end.

%% --- Notifications ---

fun_notify() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [PlayerId, Type, Subject, Data] when
                is_binary(PlayerId), is_binary(Type), is_binary(Subject)
            ->
                wrap_result(asobi_notify:send(PlayerId, Type, Subject, to_map(Data)), St);
            [PlayerId, Type, Subject] when
                is_binary(PlayerId), is_binary(Type), is_binary(Subject)
            ->
                wrap_result(asobi_notify:send(PlayerId, Type, Subject, #{}), St);
            _ ->
                error_result(~"notify requires (player_id, type, subject[, data])", St)
        end
    end.

fun_notify_many() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [PlayerIds, Type, Subject, Data] when
                is_list(PlayerIds), is_binary(Type), is_binary(Subject)
            ->
                Ids = [Id || Id <- PlayerIds, is_binary(Id)],
                Sent = asobi_notify:send_many(Ids, Type, Subject, to_map(Data)),
                ok_result(Sent, St);
            [PlayerIds, Type, Subject] when
                is_list(PlayerIds), is_binary(Type), is_binary(Subject)
            ->
                Ids = [Id || Id <- PlayerIds, is_binary(Id)],
                Sent = asobi_notify:send_many(Ids, Type, Subject, #{}),
                ok_result(Sent, St);
            _ ->
                error_result(~"notify_many requires (player_ids, type, subject[, data])", St)
        end
    end.

%% --- Storage ---

fun_storage_get() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [Collection, Key] when is_binary(Collection), is_binary(Key) ->
                wrap_result(storage_get(Collection, Key, undefined), St);
            _ ->
                error_result(~"get requires (collection, key)", St)
        end
    end.

fun_storage_set() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [Collection, Key, Value] when is_binary(Collection), is_binary(Key) ->
                wrap_result(storage_set(Collection, Key, undefined, to_map(Value)), St);
            _ ->
                error_result(~"set requires (collection, key, value)", St)
        end
    end.

fun_storage_player_get() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [PlayerId, Collection, Key] when
                is_binary(PlayerId), is_binary(Collection), is_binary(Key)
            ->
                wrap_result(storage_get(Collection, Key, PlayerId), St);
            _ ->
                error_result(~"player_get requires (player_id, collection, key)", St)
        end
    end.

fun_storage_player_set() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [PlayerId, Collection, Key, Value] when
                is_binary(PlayerId), is_binary(Collection), is_binary(Key)
            ->
                wrap_result(storage_set(Collection, Key, PlayerId, to_map(Value)), St);
            _ ->
                error_result(~"player_set requires (player_id, collection, key, value)", St)
        end
    end.

%% --- Chat ---

fun_chat_send() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [ChannelId, SenderId, Content] when
                is_binary(ChannelId), is_binary(SenderId), is_binary(Content)
            ->
                asobi_chat_channel:send_message(ChannelId, SenderId, Content),
                {[true], St};
            _ ->
                error_result(~"chat.send requires (channel_id, sender_id, content)", St)
        end
    end.

%% --- Spatial ---

fun_spatial_query_radius(Ctx) ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [X, Y, Radius] when is_number(X), is_number(Y), is_number(Radius) ->
                case maps:find(zone_pid, Ctx) of
                    {ok, ZonePid} ->
                        Results = asobi_zone:query_radius(ZonePid, {X, Y}, Radius),
                        encode_zone_spatial_results(Results, St);
                    error ->
                        error_result(~"query_radius(x, y, radius) requires zone context", St)
                end;
            [Entities, X, Y, Radius] when
                is_map(Entities), is_number(X), is_number(Y), is_number(Radius)
            ->
                Results = asobi_spatial:query_radius(atomize_entities(Entities), {X, Y}, Radius),
                encode_spatial_results(Results, St);
            [Entities, X, Y, Radius, OptsRaw] when
                is_map(Entities), is_number(X), is_number(Y), is_number(Radius)
            ->
                Opts = decode_spatial_opts(OptsRaw),
                Results = asobi_spatial:query_radius(
                    atomize_entities(Entities), {X, Y}, Radius, Opts
                ),
                encode_spatial_results(Results, St);
            _ ->
                error_result(
                    ~"query_radius requires (x, y, radius) or (entities, x, y, radius[, opts])", St
                )
        end
    end.

fun_spatial_query_rect(#{zone_pid := ZonePid}) ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [X1, Y1, X2, Y2] when
                is_number(X1), is_number(Y1), is_number(X2), is_number(Y2)
            ->
                Results = asobi_zone:query_rect(ZonePid, {X1, Y1}, {X2, Y2}),
                encode_zone_spatial_results(Results, St);
            _ ->
                error_result(~"query_rect requires (x1, y1, x2, y2)", St)
        end
    end;
fun_spatial_query_rect(_) ->
    fun(_, St) -> error_result(~"query_rect requires zone context", St) end.

fun_spatial_nearest() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [Entities, X, Y, N] when is_map(Entities), is_number(X), is_number(Y), is_number(N) ->
                Results = asobi_spatial:nearest(atomize_entities(Entities), {X, Y}, trunc(N)),
                encode_spatial_results(Results, St);
            [Entities, X, Y, N, OptsRaw] when
                is_map(Entities), is_number(X), is_number(Y), is_number(N)
            ->
                Opts = decode_spatial_opts(OptsRaw),
                Results = asobi_spatial:nearest(atomize_entities(Entities), {X, Y}, trunc(N), Opts),
                encode_spatial_results(Results, St);
            _ ->
                error_result(~"nearest requires (entities, x, y, n[, opts])", St)
        end
    end.

fun_spatial_in_range() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [A, B, Range] when is_map(A), is_map(B), is_number(Range) ->
                Result = asobi_spatial:in_range(atomize_keys(A), atomize_keys(B), Range),
                {[Result], St};
            _ ->
                error_result(~"in_range requires (entity_a, entity_b, range)", St)
        end
    end.

fun_spatial_distance() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [A, B] when is_map(A), is_map(B) ->
                D = asobi_spatial:distance(atomize_keys(A), atomize_keys(B)),
                {[D], St};
            _ ->
                error_result(~"distance requires (entity_a, entity_b)", St)
        end
    end.

encode_spatial_results(Results, St) ->
    Encoded = [
        #{~"id" => Id, ~"entity" => Entity, ~"distance" => Dist}
     || {Id, Entity, Dist} <- Results
    ],
    {Enc, St1} = luerl:encode(Encoded, St),
    {[Enc], St1}.

encode_zone_spatial_results(Results, St) ->
    Encoded = [
        #{~"id" => Id, ~"x" => X, ~"y" => Y}
     || {Id, {X, Y}} <- Results
    ],
    {Enc, St1} = luerl:encode(Encoded, St),
    {[Enc], St1}.

decode_spatial_opts(OptsRaw) when is_map(OptsRaw) ->
    Opts0 = #{},
    Opts1 =
        case maps:find(~"type", OptsRaw) of
            {ok, T} when is_binary(T) -> Opts0#{type => T};
            {ok, T} when is_list(T) -> Opts0#{type => [B || B <- T, is_binary(B)]};
            _ -> Opts0
        end,
    Opts2 =
        case maps:find(~"exclude", OptsRaw) of
            {ok, E} when is_binary(E) -> Opts1#{exclude => E};
            {ok, E} when is_list(E) -> Opts1#{exclude => [B || B <- E, is_binary(B)]};
            _ -> Opts1
        end,
    Opts3 =
        case maps:find(~"max_results", OptsRaw) of
            {ok, N} when is_number(N) -> Opts2#{max_results => trunc(N)};
            _ -> Opts2
        end,
    case maps:find(~"sort", OptsRaw) of
        {ok, ~"nearest"} -> Opts3#{sort => nearest};
        {ok, ~"farthest"} -> Opts3#{sort => farthest};
        _ -> Opts3
    end;
decode_spatial_opts(_) ->
    #{}.

%% --- Zone spawning ---

fun_zone_spawn(#{zone_pid := ZonePid}) ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [TemplateId, X, Y] when is_binary(TemplateId), is_number(X), is_number(Y) ->
                asobi_zone:spawn_entity(ZonePid, TemplateId, {X, Y}),
                {[true], St};
            [TemplateId, X, Y, Overrides] when
                is_binary(TemplateId), is_number(X), is_number(Y), is_map(Overrides)
            ->
                asobi_zone:spawn_entity(ZonePid, TemplateId, {X, Y}, Overrides),
                {[true], St};
            _ ->
                error_result(~"zone.spawn requires (template_id, x, y[, overrides])", St)
        end
    end;
fun_zone_spawn(_) ->
    fun(_, St) -> error_result(~"zone.spawn not available (no zone context)", St) end.

fun_zone_despawn(#{zone_pid := ZonePid}) ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [EntityId] when is_binary(EntityId) ->
                asobi_zone:despawn_entity(ZonePid, EntityId),
                {[true], St};
            _ ->
                error_result(~"zone.despawn requires (entity_id)", St)
        end
    end;
fun_zone_despawn(_) ->
    fun(_, St) -> error_result(~"zone.despawn not available (no zone context)", St) end.

%% --- Terrain ---

fun_terrain_get_chunk(#{terrain_store_pid := Pid}) when is_pid(Pid) ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [CX, CY] when is_number(CX), is_number(CY) ->
                case asobi_terrain_store:get_chunk(Pid, {trunc(CX), trunc(CY)}) of
                    {ok, Data} ->
                        ok_result(Data, St);
                    {error, Reason} ->
                        error_result(Reason, St)
                end;
            _ ->
                error_result(~"get_chunk requires (cx, cy)", St)
        end
    end;
fun_terrain_get_chunk(_) ->
    fun(_, St) -> error_result(~"terrain not available (no terrain store)", St) end.

fun_terrain_preload(#{terrain_store_pid := Pid}) when is_pid(Pid) ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [CoordsList] when is_list(CoordsList) ->
                Coords = lists:filtermap(
                    fun
                        (M) when is_map(M) ->
                            CX = maps:get(~"cx", M, maps:get(~"x", M, undefined)),
                            CY = maps:get(~"cy", M, maps:get(~"y", M, undefined)),
                            case {CX, CY} of
                                {X, Y} when is_number(X), is_number(Y) ->
                                    {true, {trunc(X), trunc(Y)}};
                                _ ->
                                    false
                            end;
                        (_) ->
                            false
                    end,
                    CoordsList
                ),
                asobi_terrain_store:preload_chunks(Pid, Coords),
                {[true], St};
            _ ->
                error_result(~"preload requires (coords_list)", St)
        end
    end;
fun_terrain_preload(_) ->
    fun(_, St) -> error_result(~"terrain not available (no terrain store)", St) end.

%% --- Storage helpers ---

-spec storage_get(binary(), binary(), binary() | undefined) -> {ok, map()} | {error, term()}.
storage_get(Collection, Key, PlayerId) ->
    Q0 = kura_query:from(asobi_storage),
    Q1 = kura_query:where(Q0, {collection, Collection}),
    Q2 = kura_query:where(Q1, {key, Key}),
    Q3 = maybe_filter_player(Q2, PlayerId),
    case asobi_repo:all(Q3) of
        {ok, [Doc | _]} -> {ok, maps:get(value, Doc, #{})};
        {ok, []} -> {error, not_found};
        {error, _} = Err -> Err
    end.

-spec storage_set(binary(), binary(), binary() | undefined, map()) -> {ok, map()} | {error, term()}.
storage_set(Collection, Key, PlayerId, Value) ->
    case storage_get(Collection, Key, PlayerId) of
        {ok, _} ->
            storage_update(Collection, Key, PlayerId, Value);
        {error, not_found} ->
            storage_insert(Collection, Key, PlayerId, Value);
        {error, _} = Err ->
            Err
    end.

storage_insert(Collection, Key, PlayerId, Value) ->
    Params = #{
        collection => Collection,
        key => Key,
        value => Value,
        updated_at => calendar:universal_time()
    },
    Params1 =
        case PlayerId of
            undefined -> Params;
            _ -> Params#{player_id => PlayerId}
        end,
    CS = kura_changeset:cast(
        asobi_storage, #{}, Params1, maps:keys(Params1)
    ),
    asobi_repo:insert(CS).

storage_update(Collection, Key, PlayerId, Value) ->
    Q0 = kura_query:from(asobi_storage),
    Q1 = kura_query:where(Q0, {collection, Collection}),
    Q2 = kura_query:where(Q1, {key, Key}),
    Q3 = maybe_filter_player(Q2, PlayerId),
    asobi_repo:update_all(Q3, #{value => Value, updated_at => calendar:universal_time()}).

maybe_filter_player(Q, undefined) -> Q;
maybe_filter_player(Q, PlayerId) -> kura_query:where(Q, {player_id, PlayerId}).

%% --- Result encoding ---

-spec ok_result(term(), dynamic()) -> {[term()], dynamic()}.
ok_result(Data, St) ->
    {Enc, St1} = luerl:encode(#{~"ok" => Data}, St),
    {[Enc], St1}.

-spec error_result(term(), dynamic()) -> {[term()], dynamic()}.
error_result(Reason, St) ->
    {Enc, St1} = luerl:encode(#{~"error" => to_bin(Reason)}, St),
    {[Enc], St1}.

-spec wrap_result({ok, term()} | {error, term()}, dynamic()) -> {[term()], dynamic()}.
wrap_result({ok, Data}, St) -> ok_result(sanitize(Data), St);
wrap_result({error, Reason}, St) -> error_result(Reason, St).

%% --- Argument decoding ---

-spec decode_args([term()], dynamic()) -> [term()].
decode_args(Args, St) ->
    [deep_decode(luerl:decode(A, St)) || A <- Args].

%% Recursively turn a Luerl-decoded term into native Erlang terms.
%%
%% Luerl's `decode/2` returns Lua tables as proplists keyed by binaries
%% (string keys) or integers (sequential keys). Mixed-key tables come
%% back as a single proplist; nested tables are still proplists. This
%% function picks the right Erlang shape based on the proplist's key
%% type — string keys → map, integer keys → ordered list (re-sorted by
%% the Lua index because Luerl does not promise key order) — and
%% recurses into every value so the result is fully native.
%%
%% Defensive: `ensure_pairs/1` filters out non-`{K, V}` entries silently
%% so a malformed Lua return won't crash the caller.
%% M-5: cap recursion depth so a Lua-side table nested 100k levels deep
%% can't blow the calling gen_server's process heap. The previous
%% non-tail-recursive implementation grew the stack proportional to Lua
%% depth — a single malicious return from a callback could OOM the
%% match. 64 levels covers any realistic game state.
-define(MAX_DECODE_DEPTH, 64).

-spec deep_decode(term()) -> term().
deep_decode(V) ->
    deep_decode(V, 0).

deep_decode(_V, D) when D > ?MAX_DECODE_DEPTH ->
    %% Truncation policy: replace the over-deep subtree with an atom
    %% rather than crashing — game callers see a clear marker in the
    %% returned value.
    too_deep;
deep_decode([{K, _} | _] = PropList, D) when is_binary(K) ->
    maps:from_list([
        {Key, deep_decode(Val, D + 1)}
     || {Key, Val} <- ensure_pairs(PropList)
    ]);
deep_decode([{N, _} | _] = NumList, D) when is_integer(N) ->
    [deep_decode(Val, D + 1) || {_, Val} <- lists:sort(NumList)];
deep_decode(M, D) when is_map(M) ->
    maps:map(fun(_, V) -> deep_decode(V, D + 1) end, M);
deep_decode(L, D) when is_list(L) ->
    [deep_decode(E, D + 1) || E <- L];
deep_decode(V, _D) ->
    V.

-spec decode_to_map(term(), dynamic()) -> term().
decode_to_map(Term, LuaSt) ->
    deep_decode(luerl:decode(Term, LuaSt)).

%% --- Leaderboard encoding ---

-spec encode_lb_entries([{binary(), number(), pos_integer()}]) -> [map()].
encode_lb_entries(Entries) ->
    [
        #{~"player_id" => Id, ~"score" => Score, ~"rank" => Rank}
     || {Id, Score, Rank} <- Entries
    ].

%% --- Sanitization ---

-spec sanitize(term()) -> term().
sanitize(M) when is_map(M) ->
    Cleaned = maps:without([id, inserted_at, updated_at, '__meta__'], M),
    maps:fold(
        fun(K, V, Acc) ->
            BinK = to_bin(K),
            Acc#{BinK => sanitize(V)}
        end,
        #{},
        Cleaned
    );
sanitize(L) when is_list(L) ->
    [sanitize(E) || E <- L];
sanitize(V) ->
    V.

%% --- Utilities ---

-spec to_map(term()) -> map().
to_map(M) when is_map(M) -> M;
to_map([{K, _} | _] = PropList) when is_binary(K) ->
    to_map_acc(PropList, #{});
to_map(_) ->
    #{}.

-spec to_map_acc(list(), map()) -> map().
to_map_acc([], Acc) ->
    Acc;
to_map_acc([{K, V} | T], Acc) when is_binary(K) ->
    to_map_acc(T, Acc#{K => V});
to_map_acc([_ | T], Acc) ->
    to_map_acc(T, Acc).

-spec ensure_pairs([term()]) -> [{term(), term()}].
ensure_pairs(L) ->
    [{K, V} || {K, V} <- L].

-spec to_bin(term()) -> binary().
to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A);
to_bin(T) -> list_to_binary(io_lib:format("~p", [T])).

%% --- Entity key conversion ---
%% Lua tables use binary keys ("x"), asobi_spatial expects atom keys (x).

atomize_entities(Entities) ->
    maps:map(
        fun
            (_Id, E) when is_map(E) -> atomize_keys(E);
            (_, V) -> V
        end,
        Entities
    ).

atomize_keys(M) when is_map(M) ->
    maps:fold(
        fun(K, V, Acc) ->
            Key = safe_to_atom(K),
            Acc#{Key => V}
        end,
        #{},
        M
    ).

safe_to_atom(B) when is_binary(B) ->
    try
        binary_to_existing_atom(B)
    catch
        _:_ -> B
    end;
safe_to_atom(A) when is_atom(A) -> A;
safe_to_atom(V) ->
    V.

-spec create_table([binary()], dynamic()) -> dynamic().
create_table(Path, St) ->
    {Tab, St1} = luerl:encode(#{}, St),
    {ok, St2} = luerl:set_table_keys(Path, Tab, St1),
    St2.
