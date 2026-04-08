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
        {"math.random works", fun math_random_works/0},
        {"math.sqrt works", fun math_sqrt_works/0},
        {"math.random no args returns float", fun math_random_no_args/0}
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

%% --- Helpers ---

-spec encode_map(map(), dynamic()) -> dynamic().
encode_map(Map, St) ->
    {Enc, _} = luerl:encode(Map, St),
    Enc.
