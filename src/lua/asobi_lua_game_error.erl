-module(asobi_lua_game_error).

-moduledoc """
Emits the public `[asobi, error]` game-error telemetry for a failed Lua callback,
and provides the bounded error-rendering helpers shared by the log and dev-error
paths.

Only bounded, PII-free context crosses the telemetry boundary (which fans out to
whatever handlers an operator attached): the callback name, the script basename
(never a path), and a classified reason. The raw error reason - which can embed
player input via Lua `error()`/`assert()` - is deliberately NOT included; callers
that want a human-readable rendering use `format_reason/1`, which is length-capped
for the same reason.
""".

-include_lib("kernel/include/logger.hrl").

-export([emit/3, script_basename/1, reason_class/1, format_reason/1, bound/1]).

-define(MAX_MESSAGE_CHARS, 500).

-doc "Emit `[asobi, error]` for a failed Lua callback; only bounded, PII-free context crosses the boundary.".
%% Guarded: this runs on the per-tick Lua-error path, so a telemetry-layer fault
%% (e.g. a version skew where the asobi facade is missing) must never crash the
%% observed game loop - the observer cannot be allowed to harm the observed.
-spec emit(atom(), term(), term()) -> ok.
emit(Callback, Reason, Script) ->
    try
        asobi_telemetry:game_error(lua_error, #{
            callback => Callback,
            script => script_basename(Script),
            reason_class => reason_class(Reason)
        })
    catch
        Class:Err ->
            ?LOG_WARNING(#{msg => ~"game_error telemetry emit failed", class => Class, error => Err}),
            ok
    end.

-doc "Basename of a script path, `<<\"<unknown>\">>` for anything unexpected. Never a full path.".
-spec script_basename(term()) -> binary().
script_basename(Script) when is_binary(Script) ->
    case last_segment(binary:split(Script, ~"/", [global])) of
        %% a trailing slash / empty input yields no segment - keep it bounded
        ~"" -> ~"<unknown>";
        Seg -> Seg
    end;
script_basename(_) ->
    ~"<unknown>".

-spec last_segment([binary()]) -> binary().
last_segment([Seg]) -> Seg;
last_segment([_ | Rest]) -> last_segment(Rest);
last_segment([]) -> ~"<unknown>".

-doc "Classify a callback error reason for telemetry and logs.".
-spec reason_class(term()) -> atom().
reason_class(timeout) -> timeout;
reason_class(_) -> runtime_error.

-doc """
Human-readable, length-capped rendering of a callback error reason.

The reason can embed player input (Lua `error()`/`assert()` values), so
every rendering is bounded before it reaches a log line or a dev-mode
client message - an attacker feeding oversized input into a failing
callback must not get an unbounded write amplifier.
""".
-spec format_reason(term()) -> binary().
format_reason(timeout) ->
    ~"callback timed out";
format_reason(heap_exhausted) ->
    ~"callback exhausted its memory budget";
format_reason({lua_error, LuaErr}) ->
    Msg =
        try
            unicode:characters_to_binary(luerl_lib:format_error(LuaErr))
        catch
            _:_ -> format_term(LuaErr)
        end,
    bound(Msg);
format_reason(Other) ->
    bound(format_term(Other)).

format_term(Term) ->
    unicode:characters_to_binary(io_lib:format("~0tp", [Term])).

-doc "Cap a binary at the shared 500-char rendering budget; non-binaries become `<<\"<unprintable>\">>`.".
-spec bound(term()) -> binary().
bound(Bin) when is_binary(Bin) ->
    case string:length(Bin) > ?MAX_MESSAGE_CHARS of
        true ->
            case unicode:characters_to_binary(string:slice(Bin, 0, ?MAX_MESSAGE_CHARS)) of
                Sliced when is_binary(Sliced) -> Sliced;
                _ -> ~"<unprintable>"
            end;
        false ->
            Bin
    end;
bound(_) ->
    ~"<unprintable>".
