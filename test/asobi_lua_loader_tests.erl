-module(asobi_lua_loader_tests).
-include_lib("eunit/include/eunit.hrl").

-spec fixture(string()) -> file:filename_all().
fixture(Name) ->
    {ok, LibDir} = safe_lib_dir(),
    filename:absname(
        filename:join([LibDir, "test", "fixtures", "lua", Name])
    ).

-spec safe_lib_dir() -> {ok, string()}.
safe_lib_dir() ->
    case code:lib_dir(asobi_lua) of
        {error, bad_name} -> error(asobi_lua_not_loaded);
        Dir -> {ok, Dir}
    end.

%% --- Loader tests ---

loader_test_() ->
    [
        {"loads valid script", fun loads_valid_script/0},
        {"returns error for missing file", fun missing_file_error/0},
        {"returns error for syntax error", fun syntax_error/0},
        {"call executes lua function", fun call_function/0},
        {"call with atom name", fun call_atom_name/0},
        {"call returns error for undefined function", fun call_undefined_function/0},
        {"require loads submodule", fun require_loads_submodule/0},
        {"call with timeout succeeds", fun call_with_timeout_ok/0},
        {"call with timeout returns error on slow script", fun call_with_timeout_slow/0},
        {"call with heap cap returns error on heap bomb", fun call_heap_bomb/0},
        {"max_heap_words honors application env override", fun max_heap_env_override/0},
        {"math.random works", fun math_random_works/0},
        {"math.sqrt works", fun math_sqrt_works/0},
        {"math.random no args returns float", fun math_random_no_args/0},
        {"new/3 PreInstall runs before script eval", fun new3_pre_install_before_script/0},
        {"new/2 backwards-compat (no PreInstall)", fun new2_no_pre_install/0}
    ].

loads_valid_script() ->
    {ok, _St} = asobi_lua_loader:new(fixture("test_match.lua")).

missing_file_error() ->
    {error, {file_error, _, enoent}} = asobi_lua_loader:new(fixture("nonexistent.lua")).

syntax_error() ->
    {error, _} = asobi_lua_loader:new(fixture("bad_script.lua")).

call_function() ->
    {ok, St} = asobi_lua_loader:new(fixture("test_match.lua")),
    Cfg = encode_map(#{}, St),
    {ok, [State | _], _} = asobi_lua_loader:call(init, [Cfg], St),
    ?assert(is_map(State) orelse is_list(State) orelse is_tuple(State)).

call_atom_name() ->
    {ok, St} = asobi_lua_loader:new(fixture("test_match.lua")),
    Cfg = encode_map(#{}, St),
    {ok, [State | _], _} = asobi_lua_loader:call(init, [Cfg], St),
    ?assert(is_map(State) orelse is_list(State) orelse is_tuple(State)).

call_undefined_function() ->
    {ok, St} = asobi_lua_loader:new(fixture("test_match.lua")),
    {error, _} = asobi_lua_loader:call(nonexistent_function, [], St).

require_loads_submodule() ->
    {ok, St} = asobi_lua_loader:new(fixture("test_match.lua")),
    Cfg = encode_map(#{}, St),
    {ok, _, _} = asobi_lua_loader:call(init, [Cfg], St).

call_with_timeout_ok() ->
    {ok, St} = asobi_lua_loader:new(fixture("test_match.lua")),
    Cfg = encode_map(#{}, St),
    {ok, [_ | _], _} = asobi_lua_loader:call(init, [Cfg], St, 5000).

call_with_timeout_slow() ->
    {ok, St} = asobi_lua_loader:new(fixture("slow_tick.lua")),
    Cfg = encode_map(#{}, St),
    {error, timeout} = asobi_lua_loader:call(tick, [Cfg], St, 50).

%% A tick that allocates an unbounded table must be killed by the per-eval
%% heap cap and surface as `heap_exhausted`, not as a timeout. Use a
%% small heap budget so the eval trips quickly even on fast hardware.
call_heap_bomb() ->
    OldEnv = application:get_env(asobi_lua, max_heap_words),
    application:set_env(asobi_lua, max_heap_words, 200_000),
    try
        {ok, St} = asobi_lua_loader:new(fixture("heap_bomb.lua")),
        Cfg = encode_map(#{}, St),
        ?assertEqual(
            {error, heap_exhausted},
            asobi_lua_loader:call(tick, [Cfg], St, 5000)
        )
    after
        case OldEnv of
            {ok, V} -> application:set_env(asobi_lua, max_heap_words, V);
            undefined -> application:unset_env(asobi_lua, max_heap_words)
        end
    end.

%% A normal call still succeeds when an env override is set, proving the
%% override path is read on every eval rather than baked in once.
max_heap_env_override() ->
    OldEnv = application:get_env(asobi_lua, max_heap_words),
    application:set_env(asobi_lua, max_heap_words, 5_000_000),
    try
        {ok, St} = asobi_lua_loader:new(fixture("test_match.lua")),
        Cfg = encode_map(#{}, St),
        {ok, [_ | _], _} = asobi_lua_loader:call(init, [Cfg], St, 5000)
    after
        case OldEnv of
            {ok, V} -> application:set_env(asobi_lua, max_heap_words, V);
            undefined -> application:unset_env(asobi_lua, max_heap_words)
        end
    end.

math_random_works() ->
    {ok, St} = asobi_lua_loader:new(fixture("test_match.lua")),
    {ok, [Result | _], _} = asobi_lua_loader:call(
        [<<"math">>, <<"random">>], [10], St
    ),
    ?assert(is_number(Result)),
    ?assert(Result >= 1 andalso Result =< 10).

math_sqrt_works() ->
    {ok, St} = asobi_lua_loader:new(fixture("test_match.lua")),
    {ok, [Result | _], _} = asobi_lua_loader:call(
        [<<"math">>, <<"sqrt">>], [16.0], St
    ),
    ?assertEqual(4.0, Result).

math_random_no_args() ->
    {ok, St} = asobi_lua_loader:new(fixture("test_match.lua")),
    {ok, [Result | _], _} = asobi_lua_loader:call(
        [<<"math">>, <<"random">>], [], St
    ),
    ?assert(is_float(Result)),
    ?assert(Result >= 0.0 andalso Result < 1.0).

new3_pre_install_before_script() ->
    %% Script defines a function that closes over a global the host injects
    %% via PreInstall. If PreInstall runs BEFORE script eval, the closure's
    %% `_ENV` captures the injected value and `probe()` returns it. If it
    %% ran AFTER (the bug fixed by this hook), `probe()` would see nil.
    %% This is the same property that makes `game.*` reachable from
    %% `handle_input` in the world bridge.
    PreInstall = fun(St) ->
        {Enc, St1} = luerl:encode(~"injected_value", St),
        {ok, St2} = luerl:set_table_keys([~"injected"], Enc, St1),
        St2
    end,
    {ok, St} = asobi_lua_loader:new(
        fixture("pre_install_probe.lua"), 2000, PreInstall
    ),
    {ok, [Value | _], _} = asobi_lua_loader:call(probe, [], St),
    ?assertEqual(~"injected_value", Value).

new2_no_pre_install() ->
    %% Without PreInstall, the same script's `probe()` should see nil for
    %% the missing global. Confirms the new/3 hook is opt-in.
    {ok, St} = asobi_lua_loader:new(fixture("pre_install_probe.lua"), 2000),
    {ok, [Value | _], _} = asobi_lua_loader:call(probe, [], St),
    ?assertEqual(nil, Value).

%% --- Helpers ---

-spec encode_map(map(), dynamic()) -> dynamic().
encode_map(Map, St) ->
    {Enc, _} = luerl:encode(Map, St),
    Enc.
