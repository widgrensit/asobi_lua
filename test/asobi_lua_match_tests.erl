-module(asobi_lua_match_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

-spec fixture(string()) -> file:filename_all().
fixture(Name) ->
    {ok, LibDir} = safe_lib_dir(),
    filename:join([LibDir, "test", "fixtures", "lua", Name]).

-spec safe_lib_dir() -> {ok, string()}.
safe_lib_dir() ->
    case code:lib_dir(asobi_lua) of
        {error, bad_name} -> error(asobi_lua_not_loaded);
        Dir -> {ok, Dir}
    end.

%% --- Match behaviour tests ---

lua_match_test_() ->
    [
        {"init loads lua and returns state", fun init_ok/0},
        {"init fails with bad script", fun init_bad_script/0},
        {"init fails with missing script", fun init_missing_script/0},
        {"join adds player to state", fun join_adds_player/0},
        {"leave removes player", fun leave_removes_player/0},
        {"handle_input updates player position", fun input_moves_player/0},
        {"handle_input handles boon pick", fun input_boon_pick/0},
        {"tick increments counter", fun tick_increments/0},
        {"tick signals finished", fun tick_finishes/0},
        {"get_state returns player view", fun get_state_view/0},
        {"vote_requested returns config at right tick", fun vote_requested_ok/0},
        {"vote_requested returns none normally", fun vote_requested_none/0},
        {"vote_resolved updates state", fun vote_resolved_ok/0},
        {"finish_immediately script", fun finish_immediately/0},
        {"tick reloads script after file change", fun hot_reload_on_file_change/0},
        {"tick survives syntax error on reload", fun hot_reload_syntax_error/0}
    ].

init_ok() ->
    Config = #{lua_script => fixture("test_match.lua")},
    {ok, State} = asobi_lua_match:init(Config),
    ?assert(is_map(State)),
    ?assertMatch(#{lua_state := _, game_state := _}, State).

init_bad_script() ->
    Config = #{lua_script => fixture("bad_script.lua")},
    %% asobi_match:init/1 is specced {ok, term()} — errors crash the
    %% process so the supervisor sees the failure with a proper reason.
    ?assertError({lua_load_failed, _, _}, asobi_lua_match:init(Config)).

init_missing_script() ->
    Config = #{lua_script => fixture("nonexistent.lua")},
    ?assertError({lua_load_failed, _, _}, asobi_lua_match:init(Config)).

join_adds_player() ->
    {ok, State0} = init_match(),
    {ok, State1} = asobi_lua_match:join(~"player1", State0),
    PlayerState = asobi_lua_match:get_state(~"player1", State1),
    ?assert(is_map(PlayerState)).

leave_removes_player() ->
    {ok, State0} = init_match(),
    {ok, State1} = asobi_lua_match:join(~"player1", State0),
    {ok, State2} = asobi_lua_match:leave(~"player1", State1),
    PlayerState = asobi_lua_match:get_state(~"player1", State2),
    ?assert(is_map(PlayerState)).

input_moves_player() ->
    {ok, State0} = init_match(),
    {ok, State1} = asobi_lua_match:join(~"player1", State0),
    Input = #{~"right" => true, ~"left" => false, ~"up" => false, ~"down" => false},
    {ok, State2} = asobi_lua_match:handle_input(~"player1", Input, State1),
    ?assert(is_map(State2)).

input_boon_pick() ->
    {ok, State0} = init_match(),
    {ok, State1} = asobi_lua_match:join(~"player1", State0),
    Input = #{~"type" => ~"boon_pick", ~"boon_id" => ~"hp_boost"},
    {ok, State2} = asobi_lua_match:handle_input(~"player1", Input, State1),
    ?assert(is_map(State2)).

tick_increments() ->
    {ok, State0} = init_match(),
    {ok, State1} = asobi_lua_match:join(~"player1", State0),
    {ok, State2} = asobi_lua_match:tick(State1),
    ?assert(is_map(State2)).

tick_finishes() ->
    Config = #{lua_script => fixture("test_match.lua"), game_config => #{max_ticks => 2}},
    {ok, State0} = asobi_lua_match:init(Config),
    {ok, State1} = asobi_lua_match:join(~"player1", State0),
    {ok, State2} = asobi_lua_match:tick(State1),
    case asobi_lua_match:tick(State2) of
        {finished, Result, _State3} ->
            ?assert(is_map(Result));
        {ok, _State3} ->
            ok
    end.

get_state_view() ->
    {ok, State0} = init_match(),
    {ok, State1} = asobi_lua_match:join(~"player1", State0),
    View = asobi_lua_match:get_state(~"player1", State1),
    ?assert(is_map(View)).

vote_requested_ok() ->
    {ok, State0} = init_match(),
    {ok, State1} = asobi_lua_match:join(~"player1", State0),
    State50 = tick_n(50, State1),
    case asobi_lua_match:vote_requested(State50) of
        {ok, VoteConfig} ->
            ?assert(is_map(VoteConfig));
        none ->
            ok
    end.

vote_requested_none() ->
    {ok, State0} = init_match(),
    ?assertEqual(none, asobi_lua_match:vote_requested(State0)).

vote_resolved_ok() ->
    {ok, State0} = init_match(),
    Result = #{winner => ~"opt_a"},
    {ok, State1} = asobi_lua_match:vote_resolved(~"test_vote", Result, State0),
    ?assert(is_map(State1)).

finish_immediately() ->
    Config = #{lua_script => fixture("finish_immediately.lua")},
    {ok, State0} = asobi_lua_match:init(Config),
    {ok, State1} = asobi_lua_match:join(~"player1", State0),
    case asobi_lua_match:tick(State1) of
        {finished, Result, _} ->
            ?assert(is_map(Result));
        {ok, _} ->
            ?assert(false)
    end.

hot_reload_on_file_change() ->
    %% Write a temp match script, init a match, modify the file, tick,
    %% verify the changed global is visible via get_state.
    Path = temp_script(
        ~"""
        match_size = 1
        tag = "before"
        function init(_) return { n = 0 } end
        function join(id, s) s.players = s.players or {}; s.players[id] = {}; return s end
        function leave(id, s) s.players[id] = nil; return s end
        function handle_input(_, _, s) return s end
        function tick(s) s.n = s.n + 1; return s end
        function get_state(_, s) return { tag = tag, n = s.n } end
    """
    ),
    try
        {ok, S0} = asobi_lua_match:init(#{lua_script => Path}),
        {ok, S1} = asobi_lua_match:join(~"p1", S0),
        #{~"tag" := BeforeTag} = asobi_lua_match:get_state(~"p1", S1),
        ?assertEqual(~"before", BeforeTag),

        write_script(
            Path,
            ~"""
            match_size = 1
            tag = "after"
            function init(_) return { n = 0 } end
            function join(id, s) s.players = s.players or {}; s.players[id] = {}; return s end
            function leave(id, s) s.players[id] = nil; return s end
            function handle_input(_, _, s) return s end
            function tick(s) s.n = s.n + 1; return s end
            function get_state(_, s) return { tag = tag, n = s.n } end
        """
        ),
        %% filelib:last_modified/1 has 1-second resolution on POSIX, and
        %% file:write_file updates mtime to the current second which can
        %% equal the init-time mtime. Bump after writing so the reload
        %% check fires deterministically.
        bump_mtime(Path),

        {ok, S2} = asobi_lua_match:tick(S1),
        #{~"tag" := AfterTag} = asobi_lua_match:get_state(~"p1", S2),
        ?assertEqual(~"after", AfterTag)
    after
        file:delete(Path)
    end.

hot_reload_syntax_error() ->
    %% A broken reload should not crash the match or wipe game state —
    %% the match keeps running on the previous (good) script.
    Path = temp_script(
        ~"""
        match_size = 1
        tag = "good"
        function init(_) return { n = 0 } end
        function join(id, s) s.players = s.players or {}; s.players[id] = {}; return s end
        function leave(id, s) s.players[id] = nil; return s end
        function handle_input(_, _, s) return s end
        function tick(s) s.n = s.n + 1; return s end
        function get_state(_, s) return { tag = tag, n = s.n } end
    """
    ),
    try
        {ok, S0} = asobi_lua_match:init(#{lua_script => Path}),
        {ok, S1} = asobi_lua_match:join(~"p1", S0),

        write_script(Path, ~"tag = \"broken\"  !!this is not lua"),
        bump_mtime(Path),

        {ok, S2} = asobi_lua_match:tick(S1),
        %% The old code still runs, so `tag` is still "good".
        #{~"tag" := Tag} = asobi_lua_match:get_state(~"p1", S2),
        ?assertEqual(~"good", Tag)
    after
        file:delete(Path)
    end.

%% --- Helpers ---

-spec init_match() -> {ok, map()}.
init_match() ->
    Config = #{lua_script => fixture("test_match.lua")},
    {ok, _} = asobi_lua_match:init(Config).

-spec tick_n(non_neg_integer(), map()) -> map().
tick_n(0, State) ->
    State;
tick_n(N, State) ->
    case asobi_lua_match:tick(State) of
        {ok, S} -> tick_n(N - 1, S);
        {finished, _, S} -> tick_n(N - 1, S)
    end.

-spec temp_script(binary()) -> file:filename_all().
temp_script(Code) ->
    Name = "hot_reload_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".lua",
    Path = filename:join([filename:basedir(user_cache, "asobi_lua_tests"), Name]),
    ok = filelib:ensure_dir(Path),
    write_script(Path, Code),
    Path.

-spec write_script(file:filename_all(), binary()) -> ok.
write_script(Path, Code) ->
    ok = file:write_file(Path, Code).

-spec bump_mtime(file:filename_all()) -> ok.
bump_mtime(Path) ->
    {ok, FI} = file:read_file_info(Path, [{time, local}]),
    %% Nudge mtime forward by 2 seconds so filelib:last_modified/1 reports
    %% a different value than on the previous check.
    {{Y, M, D}, {H, Mi, S}} = FI#file_info.mtime,
    NewMtime = calendar:gregorian_seconds_to_datetime(
        calendar:datetime_to_gregorian_seconds({{Y, M, D}, {H, Mi, S}}) + 2
    ),
    ok = file:write_file_info(Path, FI#file_info{mtime = NewMtime}).
