-module(asobi_lua_api).
-moduledoc """
Installs the `game.*` Lua API into a Luerl state, giving Lua scripts
access to engine features like economy, leaderboards, notifications,
storage, and messaging.

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
```
""".

-export([install/2]).

-spec install(map(), dynamic()) -> dynamic().
install(Ctx, St0) ->
    %% Pre-create namespace tables
    St1 = create_table([~"game"], St0),
    St2 = create_table([~"game", ~"economy"], St1),
    St3 = create_table([~"game", ~"leaderboard"], St2),
    St4 = create_table([~"game", ~"storage"], St3),
    St5 = create_table([~"game", ~"chat"], St4),
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
        {[~"game", ~"chat", ~"send"], fun_chat_send()}
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

-spec deep_decode(term()) -> term().
deep_decode([{K, _} | _] = PropList) when is_binary(K) ->
    maps:from_list([{Key, deep_decode(Val)} || {Key, Val} <- ensure_pairs(PropList)]);
deep_decode([{N, _} | _] = NumList) when is_integer(N) ->
    [deep_decode(Val) || {_, Val} <- lists:sort(NumList)];
deep_decode(M) when is_map(M) ->
    maps:map(fun(_, V) -> deep_decode(V) end, M);
deep_decode(L) when is_list(L) ->
    [deep_decode(E) || E <- L];
deep_decode(V) ->
    V.

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
    maps:from_list(PropList);
to_map(_) ->
    #{}.

-spec ensure_pairs([term()]) -> [{term(), term()}].
ensure_pairs(L) ->
    [{K, V} || {K, V} <- L].

-spec to_bin(term()) -> binary().
to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A);
to_bin(T) -> list_to_binary(io_lib:format("~p", [T])).

-spec create_table([binary()], dynamic()) -> dynamic().
create_table(Path, St) ->
    {Tab, St1} = luerl:encode(#{}, St),
    {ok, St2} = luerl:set_table_keys(Path, Tab, St1),
    St2.
