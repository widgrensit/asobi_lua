-module(asobi_lua_match).
-moduledoc """
An `asobi_match` implementation that delegates all callbacks to Lua scripts
via Luerl.

Game developers write their match logic in Lua. This module bridges the
`asobi_match` behaviour to Luerl function calls.

## Configuration

In game_modes config, use `{lua, ScriptPath}` instead of a module name:

```erlang
{asobi, [
    {game_modes, #{
        ~"arena" => #{module => {lua, "priv/lua/match.lua"}, match_size => 4}
    }}
]}
```

The Lua script must define these functions:

```lua
function init(config)        -- return initial game state table
function join(player_id, state)       -- return updated state
function leave(player_id, state)      -- return updated state
function handle_input(player_id, input, state) -- return updated state
function tick(state)         -- return state, or state + finished flag
function get_state(player_id, state)  -- return state visible to player
-- Optional:
function vote_requested(state)        -- return vote config or nil
function vote_resolved(template, result, state) -- return updated state
```
""".

-behaviour(asobi_match).

-export([init/1, join/2, leave/2, handle_input/3, tick/1, get_state/2]).
-export([vote_requested/1, vote_resolved/3]).

%% A sandboxed Lua callback runs in a child process so the parent
%% gen_server stays responsive. These wall-clock budgets cap how long a
%% misbehaving script can hold the channel — `init` gets the most slack
%% because game state may be expensive to build, the per-tick callbacks
%% get the least because they run hundreds of times per second.
-define(INIT_TIMEOUT, 1000).
-define(TICK_TIMEOUT, 500).
-define(INPUT_TIMEOUT, 100).
-define(JOIN_TIMEOUT, 200).
-define(LEAVE_TIMEOUT, 200).
-define(GET_STATE_TIMEOUT, 100).
-define(VOTE_TIMEOUT, 200).

-spec init(map()) -> {ok, map()}.
init(Config) ->
    ScriptPath =
        case maps:get(lua_script, Config, undefined) of
            P when is_binary(P); is_list(P) ->
                P;
            undefined ->
                logger:error(#{msg => ~"asobi_lua_match init: missing lua_script", config => Config}),
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
            case asobi_lua_loader:call(init, [EncConfig], LuaSt1, ?INIT_TIMEOUT) of
                {ok, [GameState | _], LuaSt2} ->
                    {ok, #{
                        lua_state => LuaSt2,
                        game_state => GameState,
                        script => ScriptPath,
                        script_mtime => filelib:last_modified(ScriptPath)
                    }};
                {ok, [], _} ->
                    %% asobi_match:init/1 doesn't allow an error return; log and
                    %% crash so the supervisor handles it with full context.
                    logger:error(#{
                        msg => ~"asobi_lua_match init: lua init() returned no value",
                        script => ScriptPath
                    }),
                    erlang:error({lua_error, ~"init() must return a table"});
                {error, Reason} ->
                    logger:error(#{
                        msg => ~"asobi_lua_match init: lua init() failed",
                        script => ScriptPath,
                        reason => Reason
                    }),
                    erlang:error({lua_init_failed, Reason})
            end;
        {error, Reason} ->
            logger:error(#{
                msg => ~"asobi_lua_match init: lua_loader:new/1 failed",
                script => ScriptPath,
                reason => Reason
            }),
            erlang:error({lua_load_failed, ScriptPath, Reason})
    end.

-spec join(binary(), map()) -> {ok, map()} | {error, term()}.
join(PlayerId, #{lua_state := LuaSt, game_state := GS} = State) ->
    case asobi_lua_loader:call(join, [PlayerId, GS], LuaSt, ?JOIN_TIMEOUT) of
        {ok, [GS1 | _], LuaSt1} ->
            {ok, State#{lua_state => LuaSt1, game_state => GS1}};
        {error, Reason} ->
            logger:warning(#{msg => ~"lua join error", player_id => PlayerId, reason => Reason}),
            {error, Reason}
    end.

-spec leave(binary(), map()) -> {ok, map()}.
leave(PlayerId, #{lua_state := LuaSt, game_state := GS} = State) ->
    case asobi_lua_loader:call(leave, [PlayerId, GS], LuaSt, ?LEAVE_TIMEOUT) of
        {ok, [GS1 | _], LuaSt1} ->
            {ok, State#{lua_state => LuaSt1, game_state => GS1}};
        {error, Reason} ->
            logger:warning(#{msg => ~"lua leave error", player_id => PlayerId, reason => Reason}),
            {ok, State}
    end.

-spec handle_input(binary(), map(), map()) -> {ok, map()}.
handle_input(PlayerId, Input, #{lua_state := LuaSt, game_state := GS} = State) ->
    {EncInput, LuaSt1} = luerl:encode(Input, LuaSt),
    case asobi_lua_loader:call(handle_input, [PlayerId, EncInput, GS], LuaSt1, ?INPUT_TIMEOUT) of
        {ok, [GS1 | _], LuaSt2} ->
            {ok, State#{lua_state => LuaSt2, game_state => GS1}};
        {error, Reason} ->
            logger:warning(#{
                msg => ~"lua input error", player_id => PlayerId, reason => Reason
            }),
            {ok, State}
    end.

-spec tick(map()) -> {ok, map()} | {finished, map(), map()}.
tick(State0) ->
    #{lua_state := LuaSt, game_state := GS} = State = maybe_hot_reload(State0),
    case asobi_lua_loader:call(tick, [GS], LuaSt, ?TICK_TIMEOUT) of
        {ok, [GS1 | _], LuaSt1} ->
            case is_finished(GS1, LuaSt1) of
                {true, Result} ->
                    {finished, Result, State#{lua_state => LuaSt1, game_state => GS1}};
                false ->
                    {ok, State#{lua_state => LuaSt1, game_state => GS1}}
            end;
        {error, timeout} ->
            logger:error(#{msg => ~"lua tick timeout", script => maps:get(script, State)}),
            {ok, State};
        {error, Reason} ->
            logger:error(#{msg => ~"lua tick error", reason => Reason}),
            {ok, State}
    end.

-spec get_state(binary(), map()) -> map().
get_state(PlayerId, #{lua_state := LuaSt, game_state := GS} = _State) ->
    case asobi_lua_loader:call(get_state, [PlayerId, GS], LuaSt, ?GET_STATE_TIMEOUT) of
        {ok, [PlayerState | _], LuaSt1} ->
            decode_to_map(PlayerState, LuaSt1);
        {error, _} ->
            #{}
    end.

-spec vote_requested(map()) -> {ok, map()} | none.
vote_requested(#{lua_state := LuaSt, game_state := GS}) ->
    case asobi_lua_loader:call(vote_requested, [GS], LuaSt, ?VOTE_TIMEOUT) of
        {ok, [nil | _], _} ->
            none;
        {ok, [false | _], _} ->
            none;
        {ok, [Config | _], LuaSt1} ->
            Decoded = decode_to_map(Config, LuaSt1),
            case map_size(Decoded) of
                0 -> none;
                _ -> {ok, Decoded}
            end;
        _ ->
            none
    end.

-spec vote_resolved(binary(), map(), map()) -> {ok, map()}.
vote_resolved(Template, Result, #{lua_state := LuaSt, game_state := GS} = State) ->
    {EncResult, LuaSt1} = luerl:encode(Result, LuaSt),
    case asobi_lua_loader:call(vote_resolved, [Template, EncResult, GS], LuaSt1, ?VOTE_TIMEOUT) of
        {ok, [GS1 | _], LuaSt2} ->
            {ok, State#{lua_state => LuaSt2, game_state => GS1}};
        {error, _} ->
            {ok, State}
    end.

%% --- Internal ---

is_finished(GS, LuaSt) ->
    try
        {ok, FinVal, LuaSt1} = luerl:get_table_key(GS, ~"_finished", LuaSt),
        case FinVal of
            true ->
                case luerl:get_table_key(GS, ~"_result", LuaSt1) of
                    {ok, ResRef, LuaSt2} -> {true, decode_to_map(ResRef, LuaSt2)};
                    _ -> {true, #{}}
                end;
            _ ->
                false
        end
    catch
        _:_ -> false
    end.

%% --- Hot reload ---
%%
%% Called at the start of every tick. If the match's source .lua file on
%% disk has been modified since the last check, re-execute the script body
%% against the current Luerl state. This re-declares globals and functions
%% in place — `cube_color = "#4facfe"` at the top of match.lua updates the
%% live global, and the next call to `get_state/2` sees the new value.
%%
%% Design notes:
%% - Lua-side match state (players, tick counters, etc.) lives inside the
%%   Luerl state so re-running the script preserves it — the script body
%%   only reassigns globals and redefines functions, it doesn't touch
%%   previously-set local variables or table fields unless you explicitly
%%   re-run `init()`.
%% - Erlang-side match state (#{game_state, ...}) is untouched.
%% - If the new script has a syntax error, we log a warning, remember the
%%   new mtime (so we don't keep retrying), and keep running the old code
%%   until the file is fixed.
-spec maybe_hot_reload(map()) -> map().
maybe_hot_reload(#{script := Path, script_mtime := OldMtime, lua_state := LuaSt} = State) ->
    case filelib:last_modified(Path) of
        0 ->
            State;
        OldMtime ->
            State;
        NewMtime ->
            case reload_script(Path, LuaSt) of
                {ok, NewLuaSt} ->
                    logger:notice(#{
                        msg => ~"lua hot reload", script => Path, mtime => NewMtime
                    }),
                    State#{lua_state => NewLuaSt, script_mtime => NewMtime};
                {error, Reason} ->
                    logger:warning(#{
                        msg => ~"lua hot reload failed",
                        script => Path,
                        reason => Reason
                    }),
                    State#{script_mtime => NewMtime}
            end
    end;
maybe_hot_reload(State) ->
    %% Legacy state from a match created before hot-reload shipped — skip.
    State.

-spec reload_script(file:filename_all(), dynamic()) -> {ok, dynamic()} | {error, term()}.
reload_script(Path, LuaSt) ->
    case file:read_file(Path) of
        {ok, Code} ->
            %% Clear the asobi_lua require cache so any `require("foo")`
            %% that runs after the reload re-reads `foo.lua` from disk.
            %% Without this, modifications to required modules (e.g.
            %% `boons.lua`) would be invisible until the match restarts.
            CleanLuaSt = clear_require_cache(LuaSt),
            try luerl:do(binary_to_list(Code), CleanLuaSt) of
                {ok, _Results, NewLuaSt} -> {ok, NewLuaSt};
                {error, Errors, _} -> {error, {lua_error, Errors}};
                Other -> {error, {unexpected, Other}}
            catch
                Class:CaughtReason -> {error, {Class, CaughtReason}}
            end;
        {error, FileReason} ->
            {error, {file_error, FileReason}}
    end.

-spec clear_require_cache(dynamic()) -> dynamic().
clear_require_cache(LuaSt) ->
    {Empty, LuaSt1} = luerl:encode(#{}, LuaSt),
    {ok, LuaSt2} = luerl:set_table_keys([~"_ASOBI_LOADED"], Empty, LuaSt1),
    LuaSt2.

decode_to_map(Term, LuaSt) ->
    asobi_lua_api:decode_to_map(Term, LuaSt).
