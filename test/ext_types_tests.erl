-module(ext_types_tests).
-include_lib("eunit/include/eunit.hrl").

compile_types_test() ->
    Source = "-module(types_fixture).\n"
             "_export\nconvert(X :: integer()) :: integer() when is_integer(X); is_float(X) ->\n"
             "    F = fun(A) -> case A of 0 -> 1; _ -> A end end, F(X);\n"
             "convert(X :: binary()) :: binary() -> X.\n"
             "_export\napply_it(F :: fun((integer()) -> integer()), X :: integer()) :: integer() -> F(X).\n",
    {ok, Output, []} = angler:transpile_with_warnings(Source, utf8),
    ?assertEqual({ok, Output}, angler:transpile(Output)),
    Path = "_build/test/types_fixture.erl",
    ok = file:write_file(Path, Output),
    try
        {ok, types_fixture, Beam, []} = compile:file(Path, [binary, return_errors, return_warnings, warnings_as_errors]),
        {module, types_fixture} = code:load_binary(types_fixture, Path, Beam),
        ?assertEqual(1, types_fixture:convert(0)),
        ?assertEqual(<<"abc">>, types_fixture:convert(<<"abc">>)),
        ?assertEqual(43, types_fixture:apply_it(fun(X) -> X+1 end, 42))
    after code:purge(types_fixture), code:delete(types_fixture), file:delete(Path) end.

conflict_test_() ->
    [?_test(begin
        {error, {_, ext_types, {spec_conflict, {f,1}, _}}} = angler:transpile(Source)
    end) || Source <- [
        "-spec f(integer())->integer(). f(X :: integer())->X.",
        "-module(m). -spec m:f(integer())->integer(). f(X :: integer())->X.",
        "-spec f(any())->integer(). f(?ARG) :: integer()->42.",
        "f(X) :: integer()->X. -spec f(integer())->integer().",
        "-spec f(any())->any(). f(X :: any()) :: any()->X."]].

identity_test_() ->
    [?_assertEqual({ok, S}, angler:transpile(S)) || S <- [
        "-spec f(integer())->integer(). f(X)->X.",
        "f(X)-> fun(A)->A; (B)->B end(X).", "% :: _export\nf()->\"::\".",
        "f(X) when is_integer(X);is_atom(X)->X."]].

fallback_test() ->
    {ok, Output, [{_, ext_types, {partial_overload, {f,1}}}]} =
        angler:transpile_with_warnings("f(X :: integer()) -> X; f(X)->X.", utf8),
    ?assert(string:find(Output, "any()") =/= nomatch),
    {ok, AnyOutput, []} = angler:transpile_with_warnings("f(X :: any()) :: any() -> X.", utf8),
    ?assertEqual(nomatch, string:find(AnyOutput, "-spec")),
    {ok, ReturnOutput} = angler:transpile("f(X) :: integer()->X."),
    ?assert(string:find(ReturnOutput, "any()") =/= nomatch).

invalid_test_() ->
    [?_assertMatch({error, {_, ext_types, _}}, angler:transpile(S)) || S <- [
        "f(X ::)->X.", "f(X :: integer( )->X.",
        "f({X,Y} :: tuple())->X+Y.", "f(X :: ?TYPE)->X.", "f(?ARGS, X :: integer())->X.",
        "f(X :: integer())->X; g(X)->X.", "f(X :: integer())->X; f()->ok."]].

trivia_test() ->
    S = <<239,187,191,"% caf",195,169,"\r\nf(X :: % type comment\r\n integer()) :: integer() -> X.">>,
    {ok, Out} = angler:transpile(S),
    ?assertMatch(<<239,187,191,_/binary>>, Out),
    ?assertNotEqual(nomatch, binary:match(Out, <<"% type comment\r\n">>)).

constrained_compile_test() ->
    Source = "-module(constrained_fixture).\n"
             "-export([make/2, empty/0, choose/1]).\n"
             "-type strong(T, V) :: {T, V}.\n"
             "make(Tag :: T when T :: atom(), Value :: V)\n"
             " :: (strong(T, V) when V :: integer()) when is_atom(Tag) -> {Tag, Value}.\n"
             "empty() :: (list(T) when T :: atom()) -> [].\n"
             "choose(X :: (T when T :: atom())) :: T when is_atom(X) -> X;\n"
             "choose(X :: (T when T :: integer())) :: T -> X.\n",
    {ok, Output, []} = angler:transpile_with_warnings(Source, utf8),
    ?assertEqual({ok, Output}, angler:transpile(Output)),
    Path = "_build/test/constrained_fixture.erl",
    ok = file:write_file(Path, Output),
    try
        {ok, constrained_fixture, Beam, []} = compile:file(Path,
            [binary, return_errors, return_warnings, warnings_as_errors]),
        {module, constrained_fixture} = code:load_binary(constrained_fixture, Path, Beam),
        ?assertEqual({tag, 42}, constrained_fixture:make(tag, 42)),
        ?assertEqual([], constrained_fixture:empty()),
        ?assertEqual(tag, constrained_fixture:choose(tag)),
        ?assertEqual(42, constrained_fixture:choose(42))
    after code:purge(constrained_fixture), code:delete(constrained_fixture), file:delete(Path) end.

repeated_constraints_test() ->
    {ok, Output} = angler:transpile(
        "f(X :: (T when T :: atom(), T :: integer()), Y :: (U when U :: atom()))"
        " :: (T when T :: binary()) -> X."),
    {ok, Tokens, _} = erl_scan:string(Output),
    {SpecTokens, _} = lists:splitwith(fun(T) -> erl_scan:category(T) =/= dot end, Tokens),
    Dot = lists:nth(length(SpecTokens) + 1, Tokens),
    {ok, {attribute, _, spec, {{f, 2}, [{type, _, bounded_fun, [_, Constraints]}]}}} =
        erl_parse:parse_form(SpecTokens ++ [Dot]),
    %% Preserve all constraints, including contradictions, in source order.
    ?assertMatch([
        {type, _, constraint, [_, [{var, _, 'T'}, {type, _, atom, []}]]},
        {type, _, constraint, [_, [{var, _, 'T'}, {type, _, integer, []}]]},
        {type, _, constraint, [_, [{var, _, 'U'}, {type, _, atom, []}]]},
        {type, _, constraint, [_, [{var, _, 'T'}, {type, _, binary, []}]]}
    ], Constraints).

invalid_constraints_test_() ->
    [?_assertMatch({error, _}, angler:transpile(S)) || S <- [
        "f(X :: (T when)) -> X.",
        "f(X :: (T when T ::)) -> X.",
        "f(X :: (T when T :: atom(),)) -> X.",
        "f(X :: T when) -> X.",
        "f(X :: T when T ::) -> X.",
        "f(X) :: T when T :: atom() -> X.",
        "-spec f(T)->T when T :: atom(). f(X :: (T when T :: atom())) -> X.",
        "f() -> X :: (T when T :: atom()) = tag, X."]].

argument_constraint_shorthand_test_() ->
    [?_test(begin
        {ok, Expected} = angler:transpile(Parenthesized),
        ?assertEqual({ok, Expected}, angler:transpile(Shorthand))
    end) || {Parenthesized, Shorthand} <- [
        {"f(X :: (T when T :: atom()), Y :: U) :: T -> X.",
         "f(X :: T when T :: atom(), Y :: U) :: T -> X."},
        {"f(X :: (T when T :: atom()), T :: integer()) -> X.",
         "f(X :: T when T :: atom(), T :: integer()) -> X."},
        {"f(X :: (T when T :: tuple()), {A,B}) :: T -> X.",
         "f(X :: T when T :: tuple(), {A,B}) :: T -> X."},
        {"f(X :: (T when T :: {atom(), integer()})) :: T -> X.",
         "f(X :: T when T :: {atom(), integer()}) :: T -> X."},
        {"f(X :: (T when T :: atom()), Y :: (U when U :: integer()))"
         " :: (T when T :: atom()) when is_atom(X) -> X.",
         "f(X :: T when T :: atom(), Y :: U when U :: integer())"
         " :: (T when T :: atom()) when is_atom(X) -> X."}
    ]].
