-module(ext_records_tests).
-include_lib("eunit/include/eunit.hrl").

module_execution_test() ->
    Source = "-module(records_fixture).\n"
             "-record(address, {city}).\n-record(person, {age, address}).\n"
             "_export\nbirthday(P :: #person{}) :: #person{} -> P{age = P.age + 1}.\n"
             "_export\ncity(P :: #person{}) :: atom() -> A :: #address{} = P.address, A.city.\n"
             "_export\nfetch_value(P :: #person{}) :: integer() when P.age > 0 -> P.age;\n"
             "fetch_value(P :: #address{}) :: atom() -> P.city.\n"
             "_export\nrun() -> P=#person{age=41,address=#address{city=rome}},\n"
             "    {fetch_value(birthday(P)), city(P), fetch_value(#address{city=paris}), ?LINE}.",
    {ok, Out, []} = angler:transpile_with_warnings(Source, utf8),
    ?assertEqual({ok, Out}, angler:transpile(Out)),
    ?assertEqual(newlines(Source), newlines(Out)),
    compile_run(Out, fun() -> ?assertEqual({42, rome, paris, 13}, records_fixture:run()) end).

explicit_spec_local_test() ->
    S = "-module(records_fixture). -record(person,{age}). -export([run/0]). "
        "-spec run()->integer(). run()-> P :: #person{} = #person{age=42}, P.age.",
    {ok, Out} = angler:transpile(S),
    compile_run(Out, fun() -> ?assertEqual(42, records_fixture:run()) end).

macro_record_identity_test() ->
    S = "-module(records_fixture). -record(person,{age}). -export([run/0]). "
        "-define(RECORD, #person). run()->P=#person{age=42},P?RECORD.age.",
    ?assertEqual({ok, S}, angler:transpile(S)),
    compile_run(S, fun() -> ?assertEqual(42, records_fixture:run()) end).

snippet_test() ->
    S = "P :: #person{} = #person{age=41}, P{age=P.age+1}.",
    {ok, Out} = angler:snippet(S),
    ?assertEqual(nomatch, string:find(Out, "::")),
    ?assertEqual(nomatch, string:find(Out, "-spec")),
    ?assertEqual(nomatch, string:find(Out, "-export")),
    ?assertEqual({ok, Out}, angler:snippet(Out)),
    Prefix = "-module(records_fixture). -record(person,{age}). -export([run/0]). run()-> ",
    compile_run(Prefix ++ Out, fun() -> ?assertEqual({person,42}, records_fixture:run()) end).

nested_snippet_test() ->
    S = "P :: #person{} = get_person(), A :: #address{} = P.address, A.city.",
    {ok, Out} = angler:snippet(S),
    ?assert(string:find(Out, "P#person.address") =/= nomatch),
    ?assert(string:find(Out, "A#address.city") =/= nomatch),
    ?assertEqual({ok, "N   = 42, N."}, angler:snippet("N :: integer() = 42, N.")).

errors_test_() ->
    [?_assertMatch({error, {_, ext_records, _}}, angler:snippet(S)) || S <- [
        "P.age.", "P{age=1}.",
        "P :: integer() = 42, P.age.",
        "P :: #person{} = p(), P :: #address{} = a(), P.city.",
        "P :: #person{} = p(), P.address.city.",
        "P :: #person{}, P.age.",
        "{P :: #person{}} = {p()}, P.age.",
        "[P :: #person{}] = [p()], P.age."]].

clause_reset_test() ->
    ?assertMatch({error, {_, ext_records, {unknown_record, 'P'}}},
        angler:transpile("f(P :: #person{}) -> P.age; f(P)->P.age.")),
    ?assertMatch({error, {_, ext_records, {unknown_record, 'A'}}},
        angler:transpile("f(P)->A :: #address{} = P, A.city. g(A)->A.city.")).

conflict_header_test() ->
    ?assertMatch({error, {_, ext_records, {conflicting_annotation, 'P', _}}},
        angler:transpile("f(P :: #person{}) -> P :: #address{} = p(), P.city.")),
    ?assertMatch({ok, _}, angler:snippet("P :: #person{} = p(), P :: #person{} = p(), P.age.")).

identity_test_() ->
    [?_assertEqual({ok, S}, angler:transpile(S)) || S <- [
        "f(P)-> P#person{age=P#person.age+1}.",
        "f()-> #{field => <<1,2>>}.",
        "-define(M, _export). f()->?M.",
        "f()->\"P.name P{age=1} P :: #person{}\". % P.name\n"]].

trivia_encoding_test() ->
    Source = <<239,187,191,"% caf",195,169,"\r\nP :: % annotation\r\n #person{} = p(), P % access\r\n .age.">>,
    {ok, Out} = angler:snippet(Source),
    ?assertMatch(<<239,187,191,_/binary>>, Out),
    ?assertNotEqual(nomatch, binary:match(Out, <<"% annotation\r\n">>)),
    ?assertNotEqual(nomatch, binary:match(Out, <<"% access\r\n #person.age">>)),
    Latin1 = <<"% caf",233,"\r\nP :: #person{} = p(), P.age.">>,
    ?assertMatch({ok, _}, angler:snippet(Latin1, latin1)).

compile_run(Source, Check) ->
    Path = "_build/test/records_fixture.erl",
    ok = file:write_file(Path, Source),
    try
        {ok, records_fixture, Beam, []} = compile:file(Path,
            [binary, return_errors, return_warnings, warnings_as_errors]),
        {module, records_fixture} = code:load_binary(records_fixture, Path, Beam),
        Check()
    after code:purge(records_fixture), code:delete(records_fixture), file:delete(Path) end.
newlines(S) -> length([C || C <- S, C =:= $\n]).
