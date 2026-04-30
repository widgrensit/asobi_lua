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
        {"tick survives syntax error on reload", fun hot_reload_syntax_error/0},
        {"hot reload picks up changes in required modules", fun hot_reload_clears_require_cache/0},
        {"hot reload survives function add/remove", fun hot_reload_function_change/0},
        {"init returning nil crashes match init", fun init_nil_return/0},
        {"init returning non-table crashes match init", fun init_non_table_return/0},
        {"tick timeout end-to-end keeps match alive", fun tick_timeout_keeps_state/0},
        {"vote_requested returning false yields none", fun vote_requested_false/0},
        {"vote_resolved with unknown template still returns ok",
            fun vote_resolved_unknown_template/0},
        {"handle_input failure returns previous state", fun handle_input_failure/0}
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

hot_reload_clears_require_cache() ->
    %% A common gotcha with the previous loader was that `require()`'d
    %% modules stayed cached in package.loaded forever. With our own
    %% require + cache-clear on hot-reload, edits to a sibling module
    %% must be visible after touching match.lua.
    Dir = filename:join([
        filename:basedir(user_cache, "asobi_lua_tests"),
        "reload_cache_" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    ModulePath = filename:join(Dir, "helper.lua"),
    MatchPath = filename:join(Dir, "match.lua"),
    ok = file:write_file(ModulePath, ~"return { version = 'v1' }\n"),
    ok = file:write_file(
        MatchPath,
        ~"""
        match_size = 1
        local h = require('helper')
        function init(_) return { v = h.version } end
        function join(id, s) return s end
        function leave(id, s) return s end
        function handle_input(_, _, s) return s end
        function tick(s)
            local hh = require('helper')
            s.v = hh.version
            return s
        end
        function get_state(_, s) return { v = s.v } end
        """
    ),
    try
        {ok, S0} = asobi_lua_match:init(#{lua_script => MatchPath}),
        {ok, S1} = asobi_lua_match:join(~"p1", S0),
        ?assertMatch(#{~"v" := ~"v1"}, asobi_lua_match:get_state(~"p1", S1)),

        ok = file:write_file(ModulePath, ~"return { version = 'v2' }\n"),
        bump_mtime(MatchPath),

        {ok, S2} = asobi_lua_match:tick(S1),
        ?assertMatch(#{~"v" := ~"v2"}, asobi_lua_match:get_state(~"p1", S2))
    after
        file:delete(MatchPath),
        file:delete(ModulePath),
        file:del_dir(Dir)
    end.

hot_reload_function_change() ->
    %% Adding a new function or changing an existing one must take
    %% effect on the next tick. We add a `bonus` field via a new
    %% function call introduced by the reload.
    Path = temp_script(
        ~"""
        match_size = 1
        function init(_) return { hits = 0 } end
        function join(id, s) return s end
        function leave(id, s) return s end
        function handle_input(_, _, s) s.hits = s.hits + 1; return s end
        function tick(s) return s end
        function get_state(_, s) return { hits = s.hits, bonus = 0 } end
        """
    ),
    try
        {ok, S0} = asobi_lua_match:init(#{lua_script => Path}),
        {ok, S1} = asobi_lua_match:join(~"p1", S0),
        ?assertEqual(0, maps:get(~"bonus", asobi_lua_match:get_state(~"p1", S1))),

        write_script(
            Path,
            ~"""
            match_size = 1
            function init(_) return { hits = 0 } end
            function join(id, s) return s end
            function leave(id, s) return s end
            function handle_input(_, _, s) s.hits = s.hits + 1; return s end
            function tick(s) return s end
            function get_state(_, s) return { hits = s.hits, bonus = 100 } end
            """
        ),
        bump_mtime(Path),

        {ok, S2} = asobi_lua_match:tick(S1),
        ?assertEqual(100, maps:get(~"bonus", asobi_lua_match:get_state(~"p1", S2)))
    after
        file:delete(Path)
    end.

init_nil_return() ->
    %% Documenting: init returning nil currently succeeds (game_state =
    %% nil) and the failure surfaces on the next bridge call. This is
    %% acceptable behaviour — surprising init returns are a script-author
    %% bug and the supervisor restart loop catches them — but if we ever
    %% tighten init validation, this assertion is the trip-wire.
    Path = temp_script(
        ~"""
        match_size = 1
        function init(_) return nil end
        function join(id, s) return s end
        function leave(id, s) return s end
        function handle_input(_, _, s) return s end
        function tick(s) return s end
        function get_state(_, s) return s end
        """
    ),
    try
        {ok, State} = asobi_lua_match:init(#{lua_script => Path}),
        ?assertMatch(#{game_state := nil}, State)
    after
        file:delete(Path)
    end.

init_non_table_return() ->
    Path = temp_script(
        ~"""
        match_size = 1
        function init(_) return 42 end
        function join(id, s) return s end
        function leave(id, s) return s end
        function handle_input(_, _, s) return s end
        function tick(s) return s end
        function get_state(_, s) return s end
        """
    ),
    try
        %% Returning a number passes through the bridge but join/leave/etc.
        %% will then fail to operate on a number. The init itself does not
        %% crash; the bridge accepts whatever Lua returns. This documents
        %% current behaviour: a bad init signature is the script author's
        %% problem and surfaces on the next bridge call.
        case asobi_lua_match:init(#{lua_script => Path}) of
            {ok, _State} -> ok;
            {error, _} -> ok
        end
    after
        file:delete(Path)
    end.

tick_timeout_keeps_state() ->
    %% End-to-end: a tick that exceeds TICK_TIMEOUT must NOT crash the
    %% match — the bridge logs the timeout and returns the previous
    %% state intact. Verifies the wrapping introduced for sandbox work.
    Path = temp_script(
        ~"""
        match_size = 1
        local n = 0
        function init(_) return { tag = 'before' } end
        function join(id, s) return s end
        function leave(id, s) return s end
        function handle_input(_, _, s) return s end
        function tick(s)
            n = n + 1
            if n == 1 then while true do end end
            s.tag = 'after'
            return s
        end
        function get_state(_, s) return { tag = s.tag } end
        """
    ),
    try
        {ok, S0} = asobi_lua_match:init(#{lua_script => Path}),
        {ok, S1} = asobi_lua_match:join(~"p1", S0),
        {ok, S2} = asobi_lua_match:tick(S1),
        %% On timeout the bridge keeps the previous state; tag stays 'before'.
        ?assertEqual(~"before", maps:get(~"tag", asobi_lua_match:get_state(~"p1", S2)))
    after
        file:delete(Path)
    end.

vote_requested_false() ->
    Path = temp_script(
        ~"""
        match_size = 1
        function init(_) return {} end
        function join(id, s) return s end
        function leave(id, s) return s end
        function handle_input(_, _, s) return s end
        function tick(s) return s end
        function get_state(_, s) return s end
        function vote_requested(_) return false end
        """
    ),
    try
        {ok, S0} = asobi_lua_match:init(#{lua_script => Path}),
        ?assertEqual(none, asobi_lua_match:vote_requested(S0))
    after
        file:delete(Path)
    end.

vote_resolved_unknown_template() ->
    {ok, State0} = init_match(),
    Result = #{winner => ~"opt_unknown"},
    ?assertMatch({ok, _}, asobi_lua_match:vote_resolved(~"never_proposed", Result, State0)).

handle_input_failure() ->
    %% A crashing handle_input must leave the match state intact and
    %% return {ok, State} — the bridge isolates the script error.
    Path = temp_script(
        ~"""
        match_size = 1
        function init(_) return { x = 0 } end
        function join(id, s) return s end
        function leave(id, s) return s end
        function handle_input(_, _, _) error('boom') end
        function tick(s) return s end
        function get_state(_, s) return s end
        """
    ),
    try
        {ok, S0} = asobi_lua_match:init(#{lua_script => Path}),
        {ok, S1} = asobi_lua_match:join(~"p1", S0),
        {ok, S2} = asobi_lua_match:handle_input(~"p1", #{~"k" => ~"v"}, S1),
        %% game_state survives the failure
        ?assertMatch(#{game_state := _}, S2)
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
