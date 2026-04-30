-module(asobi_lua_quirks_tests).
-include_lib("eunit/include/eunit.hrl").

%% Tests for Luerl 1.5 quirks that diverge from upstream Lua. Each
%% test pins the current behaviour so we notice if Luerl changes it
%% under us, and so script authors can read this file when something
%% surprises them.

-spec fixture(string()) -> file:filename_all().
fixture(Name) ->
    {ok, LibDir} = safe_lib_dir(),
    filename:absname(filename:join([LibDir, "test", "fixtures", "lua", Name])).

-spec safe_lib_dir() -> {ok, string()}.
safe_lib_dir() ->
    case code:lib_dir(asobi_lua) of
        {error, bad_name} -> error(asobi_lua_not_loaded);
        Dir -> {ok, Dir}
    end.

%% --- math.random override edge cases ---

math_random_zero_returns_float_test() ->
    %% Upstream Lua errors on math.random(0). asobi_lua's override
    %% falls into the catch-all and returns a float in [0, 1) — not
    %% identical to upstream but consistent and documented.
    St = fresh_state(),
    {ok, [Result | _], _} = asobi_lua_loader:call(
        [~"math", ~"random"], [0], St
    ),
    ?assert(is_float(Result)),
    ?assert(Result >= 0.0 andalso Result < 1.0).

math_random_two_args_unsupported_test() ->
    %% Upstream `math.random(1, 6)` returns an integer in [1,6].
    %% asobi_lua's override drops the second arg silently.
    St = fresh_state(),
    {ok, [Result | _], _} = asobi_lua_loader:call(
        [~"math", ~"random"], [1, 6], St
    ),
    %% With N=1 the override returns rand:uniform(1) = 1.
    ?assertEqual(1, Result).

math_sqrt_negative_returns_default_test() ->
    %% Erlang's math:sqrt/1 errors on negative numbers and upstream Lua
    %% returns NaN. Our override returns 0.0 — a pragmatic compromise
    %% that keeps the callback from crashing.
    St = fresh_state(),
    {ok, [Result | _], _} = asobi_lua_loader:call(
        [~"math", ~"sqrt"], [-1], St
    ),
    ?assertEqual(0.0, Result).

%% --- String / number edge cases ---

very_long_string_round_trips_test() ->
    %% Build a 1MB Lua string, send it through encode/decode and
    %% confirm the bridge can handle it without truncation or stack
    %% overflow. Smaller than what mobile clients send but big enough
    %% to flag pathological behaviour.
    St = fresh_state(),
    Code =
        "local s = string.rep('x', 1024 * 1024)\n"
        "return #s",
    {ok, [Len | _], _} = luerl_do(Code, St),
    ?assertEqual(1024 * 1024, trunc(Len)).

%% --- Table iteration / nesting ---

deeply_nested_table_round_trip_test() ->
    %% deep_decode/1 walks tables recursively. 100 levels of nesting
    %% is plenty for any realistic game state. Anything that blows
    %% the stack here would be a problem on mobile clients sending
    %% nested chat history or replay payloads. Built iteratively so
    %% Luerl's recursion limit (lower than the BEAM's) doesn't bite.
    St = fresh_state(),
    Code =
        "local t = { leaf = true }\n"
        "for i = 1, 100 do\n"
        "  t = { child = t }\n"
        "end\n"
        "return t",
    {ok, [Result | _], St1} = luerl_do(Code, St),
    Decoded = asobi_lua_api:deep_decode(luerl:decode(Result, St1)),
    ?assert(is_map(Decoded)).

empty_table_decode_test() ->
    %% An empty Lua table decodes to []. The bridge must accept that
    %% — many callbacks return `{}` to mean "no change".
    St = fresh_state(),
    Code = "return {}",
    {ok, [Result | _], St1} = luerl_do(Code, St),
    ?assertEqual([], luerl:decode(Result, St1)).

%% --- Coroutines / pcall ---

coroutine_unavailable_test() ->
    %% Luerl 1.5.1 does not ship a `coroutine` library. Scripts that
    %% reach for `coroutine.create` see nil. Documenting so an author
    %% who tries it knows to drop the script-level coroutine plan.
    St = fresh_state(),
    Code = "return type(coroutine)",
    {ok, [Result | _], _} = luerl_do(Code, St),
    ?assertEqual(~"nil", Result).

pcall_over_nil_function_does_not_crash_test() ->
    %% Calling pcall(nil) shouldn't kill the bridge — it should just
    %% return false from pcall, which is standard Lua behaviour and
    %% Luerl mirrors it.
    St = fresh_state(),
    Code = "local ok = pcall(nil)\nreturn ok",
    {ok, [Result | _], _} = luerl_do(Code, St),
    ?assertEqual(false, Result).

%% --- Numeric edge cases ---

division_by_zero_raises_lua_error_test() ->
    %% Lua 5.3 returns inf for 1/0; Luerl propagates Erlang's badarith
    %% as a lua_error. A script doing 1/0 outside pcall would crash the
    %% callback; inside pcall it traps cleanly. Documenting both paths.
    St = fresh_state(),
    Code = "local ok = pcall(function() return 1/0 end)\nreturn ok",
    {ok, [Result | _], _} = luerl_do(Code, St),
    ?assertEqual(false, Result).

negative_score_truncation_test() ->
    %% asobi_lua_api uses trunc/1 on numeric values heading into
    %% leaderboard.submit/economy.grant. trunc(-1.5) = -1, NOT -2 (Lua's
    %% math.floor would give -2). Documenting this divergence so a
    %% game author who expects floor-rounding reads the test and adjusts.
    ?assertEqual(-1, trunc(-1.5)).

%% --- Helpers ---

fresh_state() ->
    {ok, St} = asobi_lua_loader:new(fixture("test_match.lua")),
    St.

luerl_do(Code, St) ->
    case luerl:do(Code, St) of
        {ok, Results, St1} -> {ok, Results, St1};
        Other -> Other
    end.
