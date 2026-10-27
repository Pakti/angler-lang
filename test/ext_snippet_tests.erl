-module(ext_snippet_tests).
-include_lib("eunit/include/eunit.hrl").

identity_test_() ->
    Sources = ["", "% comment without newline", " \t\r\n",
        "X = 40, X + 2.", "P#person{age = P#person.age + 1}.\n",
        "F = fun(X) -> case X of ok -> 42; _ -> 0 end end, F(ok).\r\n",
        "_export = ok, _export.", "-abs(42).",
        "\"caf" ++ [233, 16#1f41f] ++ "\".", "erlang:halt()."],
    [?_assertEqual({ok, Source}, angler:snippet(Source)) || Source <- Sources] ++
    [?_assertEqual({ok, Bytes}, angler:snippet(Bytes)) || Source <- Sources,
        Bytes <- [unicode:characters_to_binary(Source)]].

errors_test_() ->
    Sources = ["X =", "42", "one. two.", "f()->ok.",
               "_export f()->ok.", "-module(m).", "-export([f/0]).",
               "P :: #person{} = get_person(), P.name.", "P.name."],
    [?_assertMatch({error, {_, _, _}}, angler:snippet(Source)) || Source <- Sources].

encoding_test() ->
    Source = <<"% caf", 233, "\r\n42.">>,
    ?assertEqual({ok, Source}, angler:snippet(Source, latin1)),
    ?assertEqual({error, {invalid_encoding, utf8}}, angler:snippet(Source)),
    Bom = <<239, 187, 191, "42.">>,
    ?assertEqual({ok, Bom}, angler:snippet(Bom)).

shell_execution_test() ->
    {ok, Output} = angler:snippet("X = 40, X + 2."),
    {ok, Document} = ext_scan:scan(Output),
    {ok, Expressions} = erl_parse:parse_exprs(
        [T || {_, T} <- ext_scan:significant(Document)]),
    ?assertMatch({value, 42, _}, erl_eval:exprs(Expressions, erl_eval:new_bindings())).
