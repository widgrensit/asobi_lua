-module(asobi_lua_game_error).

-moduledoc """
Emits the public `[asobi, error]` game-error telemetry for a failed Lua callback.

Only bounded, PII-free context crosses the telemetry boundary (which fans out to
whatever handlers an operator attached): the callback name, the script basename
(never a path), and a classified reason. The raw error reason - which can embed
player input via Lua `error()`/`assert()` - is deliberately NOT included; callers
keep it in their own local log.
""".

-include_lib("kernel/include/logger.hrl").

-export([emit/3]).

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

-spec reason_class(term()) -> atom().
reason_class(timeout) -> timeout;
reason_class(_) -> runtime_error.
