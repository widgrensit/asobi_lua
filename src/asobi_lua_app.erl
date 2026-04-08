-module(asobi_lua_app).
-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_StartType, _StartArgs) ->
    case asobi_lua_config:maybe_load_game_config() of
        ok ->
            ok;
        {error, ConfigErr} ->
            logger:error(#{msg => ~"game_config_failed", error => ConfigErr}),
            error({game_config_failed, ConfigErr})
    end,
    case asobi_lua_sup:start_link() of
        {ok, Pid} -> {ok, Pid};
        ignore -> {error, supervisor_ignored};
        {error, _} = Err -> Err
    end.

-spec stop(term()) -> ok.
stop(_State) ->
    ok.
