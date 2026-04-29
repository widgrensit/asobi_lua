-module(asobi_lua_loader).
-moduledoc """
Loads Lua scripts into a hardened Luerl state.

The state is built on top of `luerl:init/0` and then has every dangerous
standard-library entry point cleared:

- `os.execute`, `os.exit`, `os.getenv`, `os.remove`, `os.rename`,
  `os.tmpname`
- `io` (the whole library)
- `dofile`, `loadfile`, `load`, `loadstring`
- `package` (the whole library) — replaced by an `asobi_lua`-controlled
  `require/1` so scripts can still split logic across files

`require/1` resolves names relative to the directory of the script that
was loaded. Names must match `[a-zA-Z_][a-zA-Z0-9_]*(\\.[a-zA-Z_][a-zA-Z0-9_]*)*`,
so dotted module paths work (`require("bots.chaser")` →
`<base>/bots/chaser.lua`) but parent traversal (`..`), absolute paths,
and arbitrary characters are rejected. Module results are cached in a
private `_ASOBI_LOADED` table so repeat `require` calls return the same
value.

`math.random` and `math.sqrt` are overridden to call into the Erlang
`rand` and `math` modules respectively — Luerl's defaults are slower
and less deterministic than the BEAM equivalents.

Use `init_sandboxed/0` when you need a hardened state with no script
attached (e.g. for evaluating a `config.lua` manifest); use `new/1` to
load a specific script and pin its base directory for `require`.
""".

-export([new/1, init_sandboxed/0, call/3, call/4]).

-define(LOADED_TABLE, ~"_ASOBI_LOADED").

-spec new(binary() | string()) -> {ok, dynamic()} | {error, term()}.
new(ScriptPath) ->
    BaseDir = filename:dirname(to_string(ScriptPath)),
    FileName = filename:basename(to_string(ScriptPath)),
    St0 = sandboxed_state(BaseDir),
    FullPath = filename:join(BaseDir, FileName),
    case file:read_file(FullPath) of
        {ok, Code} ->
            CodeStr = binary_to_list(Code),
            try luerl:do(CodeStr, St0) of
                {ok, _Results, St1} -> {ok, St1};
                {error, Errors, _St1} -> {error, {lua_error, Errors}};
                {lua_error, Reason, _St1} -> {error, {lua_error, Reason}}
            catch
                error:{lua_error, Reason, _} -> {error, {lua_error, Reason}};
                error:Reason -> {error, Reason}
            end;
        {error, Reason} ->
            {error, {file_error, FullPath, Reason}}
    end.

-spec init_sandboxed() -> dynamic().
init_sandboxed() ->
    %% No script → no base dir → require is disabled. Used by
    %% asobi_lua_config to evaluate config manifests, which return a
    %% plain table and don't need to compose other files.
    sandboxed_state(undefined).

-spec call(atom() | [atom() | binary()], [term()], dynamic()) ->
    {ok, [term()], dynamic()} | {error, term()}.
call(FuncName, Args, St) when is_atom(FuncName) ->
    call([atom_to_binary(FuncName)], Args, St);
call(FuncPath, Args, St) ->
    BinPath = [ensure_binary(P) || P <- FuncPath],
    try
        case luerl:call_function(BinPath, Args, St) of
            {ok, Result, St1} -> {ok, Result, St1}
        end
    catch
        error:{lua_error, Reason, _} ->
            {error, {lua_error, Reason}};
        error:{try_clause, {lua_error, Reason, _}} ->
            {error, {lua_error, Reason}};
        _:_ ->
            {error, {call_failed, BinPath}}
    end.

-spec call(atom() | [atom() | binary()], [term()], dynamic(), non_neg_integer()) ->
    {ok, [term()], dynamic()} | {error, timeout | term()}.
call(FuncPath, Args, St, TimeoutMs) ->
    Self = self(),
    Ref = make_ref(),
    Pid = spawn(fun() ->
        Result = call(FuncPath, Args, St),
        Self ! {Ref, Result}
    end),
    receive
        {Ref, Result} -> Result
    after TimeoutMs ->
        exit(Pid, kill),
        receive
            {Ref, _} -> ok
        after 0 -> ok
        end,
        {error, timeout}
    end.

%% --- Internal: state construction & sandbox ---

-spec sandboxed_state(string() | binary() | undefined) -> dynamic().
sandboxed_state(BaseDir) ->
    St0 = luerl:init(),
    St1 = strip_dangerous_globals(St0),
    St2 = install_loaded_table(St1),
    St3 = install_require(BaseDir, St2),
    install_helpers(St3).

-spec strip_dangerous_globals(dynamic()) -> dynamic().
strip_dangerous_globals(St) ->
    %% Replace each entry with `nil` (rather than the atom `sandboxed`
    %% Luerl's bundled sandbox uses) so that `os.execute == nil` is the
    %% predicate scripts can check. luerl:set_table_keys/3 works on the
    %% encoded global table; setting a leaf to nil clears it without
    %% deleting the parent table.
    Paths = [
        [~"os", ~"execute"],
        [~"os", ~"exit"],
        [~"os", ~"getenv"],
        [~"os", ~"remove"],
        [~"os", ~"rename"],
        [~"os", ~"tmpname"],
        [~"dofile"],
        [~"loadfile"],
        [~"load"],
        [~"loadstring"],
        [~"io"],
        [~"package"],
        [~"require"]
    ],
    lists:foldl(
        fun(Path, Acc) ->
            {ok, Next} = luerl:set_table_keys(Path, nil, Acc),
            Next
        end,
        St,
        Paths
    ).

%% --- require: validation & resolution ---

-spec install_loaded_table(dynamic()) -> dynamic().
install_loaded_table(St) ->
    {Tab, St1} = luerl:encode(#{}, St),
    {ok, St2} = luerl:set_table_keys([?LOADED_TABLE], Tab, St1),
    St2.

-spec install_require(string() | binary() | undefined, dynamic()) -> dynamic().
install_require(undefined, St) ->
    %% No base directory → require always errors. Scripts that try it
    %% see a Lua-level error rather than a confusing nil dereference.
    Fn = fun(_Args, St0) ->
        error({lua_error, ~"require: no base directory configured", St0})
    end,
    {Enc, St1} = luerl:encode(Fn, St),
    {ok, St2} = luerl:set_table_keys([~"require"], Enc, St1),
    St2;
install_require(BaseDir, St) ->
    BaseDirBin = ensure_binary(BaseDir),
    Fn = fun(Args, St0) ->
        case Args of
            [Name | _] when is_binary(Name) ->
                handle_require(Name, BaseDirBin, St0);
            _ ->
                error({lua_error, ~"require: argument must be a string", St0})
        end
    end,
    {Enc, St1} = luerl:encode(Fn, St),
    {ok, St2} = luerl:set_table_keys([~"require"], Enc, St1),
    St2.

-spec handle_require(binary(), binary(), dynamic()) -> {[term()], dynamic()}.
handle_require(Name, BaseDir, St) ->
    case validate_module_name(Name) of
        ok ->
            case lookup_loaded(Name, St) of
                {hit, Cached, St1} ->
                    {[Cached], St1};
                {miss, St1} ->
                    load_module(Name, BaseDir, St1)
            end;
        error ->
            error({lua_error, <<"require: invalid module name: ", Name/binary>>, St})
    end.

-spec validate_module_name(binary()) -> ok | error.
validate_module_name(Name) ->
    %% Allowed: identifier (letters/digits/underscore) optionally
    %% followed by `.identifier` segments. Rejects empty, "..", "/",
    %% leading dots, trailing dots, double dots, and non-ASCII bytes.
    case re:run(Name, ~"^[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)*$", [{capture, none}]) of
        match -> ok;
        nomatch -> error
    end.

-spec lookup_loaded(binary(), dynamic()) -> {hit, term(), dynamic()} | {miss, dynamic()}.
lookup_loaded(Name, St) ->
    case luerl:get_table_keys([?LOADED_TABLE, Name], St) of
        {ok, nil, St1} -> {miss, St1};
        {ok, Value, St1} -> {hit, Value, St1}
    end.

-spec load_module(binary(), binary(), dynamic()) -> {[term()], dynamic()}.
load_module(Name, BaseDir, St) ->
    Rel = binary:replace(Name, ~".", ~"/", [global]),
    Path = filename:join(BaseDir, <<Rel/binary, ".lua">>),
    case file:read_file(Path) of
        {ok, Code} ->
            CodeStr = binary_to_list(Code),
            case luerl:do(CodeStr, St) of
                {ok, [Module | _], St1} ->
                    cache_and_return(Name, Module, St1);
                {ok, [], St1} ->
                    %% Lua convention: a module without an explicit
                    %% return is treated as `true`.
                    cache_and_return(Name, true, St1);
                {error, Errors, _} ->
                    error({lua_error, {require_failed, Name, Errors}, St});
                Other ->
                    error({lua_error, {require_failed, Name, Other}, St})
            end;
        {error, Reason} ->
            error({lua_error, {require_not_found, Name, Reason}, St})
    end.

-spec cache_and_return(binary(), term(), dynamic()) -> {[term()], dynamic()}.
cache_and_return(Name, Module, St) ->
    {ok, St1} = luerl:set_table_keys([?LOADED_TABLE, Name], Module, St),
    {[Module], St1}.

%% --- math overrides ---

-spec install_helpers(dynamic()) -> dynamic().
install_helpers(St) ->
    RandFn = fun(Args, St0) ->
        case Args of
            [] -> {[rand:uniform()], St0};
            [N | _] when is_number(N), N >= 1 -> {[rand:uniform(trunc(N))], St0};
            _ -> {[rand:uniform()], St0}
        end
    end,
    SqrtFn = fun(Args, St0) ->
        case Args of
            [N | _] when is_number(N), N >= 0 -> {[math:sqrt(N)], St0};
            %% math:sqrt errors on negatives; upstream Lua returns NaN.
            %% Returning 0.0 is a pragmatic compromise — game scripts
            %% shouldn't be feeding sqrt negative numbers, and 0.0
            %% keeps the bridge call from crashing.
            [N | _] when is_number(N) -> {[0.0], St0};
            _ -> {[0.0], St0}
        end
    end,
    {EncRand, St1} = luerl:encode(RandFn, St),
    {ok, St2} = luerl:set_table_keys([~"math", ~"random"], EncRand, St1),
    {EncSqrt, St3} = luerl:encode(SqrtFn, St2),
    {ok, St4} = luerl:set_table_keys([~"math", ~"sqrt"], EncSqrt, St3),
    St4.

%% --- utilities ---

-spec ensure_binary(binary() | atom() | string()) -> binary().
ensure_binary(B) when is_binary(B) -> B;
ensure_binary(A) when is_atom(A) -> atom_to_binary(A);
ensure_binary(L) when is_list(L) -> list_to_binary(L).

-spec to_string(binary() | string()) -> string().
to_string(B) when is_binary(B) -> binary_to_list(B);
to_string(L) when is_list(L) -> L.
