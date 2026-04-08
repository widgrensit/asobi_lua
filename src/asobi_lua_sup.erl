-module(asobi_lua_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 60
    },
    Children = [
        bot_sup(),
        bot_spawner_spec()
    ],
    {ok, {SupFlags, Children}}.

bot_sup() ->
    #{
        id => asobi_bot_sup,
        start => {asobi_bot_sup, start_link, []},
        type => supervisor
    }.

bot_spawner_spec() ->
    #{
        id => asobi_bot_spawner,
        start => {asobi_bot_spawner, start_link, []}
    }.
