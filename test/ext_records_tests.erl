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
    compile_run(Out, fun() -> ?assertEqual({42, rome, paris, 16}, records_fixture:run()) end).

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

deduction_execution_test() ->
    S = "-module(records_fixture). -record(address,{city}). "
        "-record(person,{name,age,address}). -export([run/0]). "
        "run()-> P=#person{name=\"Ada\",age=41,address=#address{city=rome}}, "
        "Older=P#person{age=P#person.age+1}, Next=Older{age=Older.age+1}, "
        "Alias=Next, \"Ada\"=Alias.name, {Alias.age,P.age}.",
    {ok, Out} = angler:transpile(S),
    ?assertEqual(nomatch, string:find(Out, "-spec")),
    ?assertEqual({ok, Out}, angler:transpile(Out)),
    compile_run(Out, fun() -> ?assertEqual({43,41}, records_fixture:run()) end).

deduction_snippet_test_() ->
    [?_test(begin
        {ok, Out} = angler:snippet(S),
        ?assert(string:find(Out, Expected) =/= nomatch),
        ?assertEqual(nomatch, string:find(Out, "-spec"))
    end) || {S, Expected} <- [
        {"P=#person{}, P.name.", "P#person.name"},
        {"P=get_person(), New=P#person{age=42}, New.age.", "New#person.age"},
        {"P=#person{}, Q=P, Q{age=42}.", "Q#person{age=42}"},
        {"P :: #person{} = get_person(), Q=P, Q.name.", "Q#person.name"},
        {"P=#person{}, Q=P{age=42}, Q.name.", "Q#person.name"},
        {"P=#person{}, P :: #person{age :: integer()} = P, P.age.", "P#person.age"},
        {"P :: #person{age :: integer()} = #person{}, P.age.", "P#person.age"}
    ]].

deduction_conflict_test_() ->
    [?_assertMatch({error, {_, ext_records, {conflicting_annotation, 'P', _}}},
                  angler:snippet(S)) || S <- [
        "P=#person{}, P=#address{}.",
        "P :: #person{} = p(), P=#address{}.",
        "P=#person{}, P :: #address{} = a().",
        "P :: integer() = #person{}."
    ]].

deduction_exclusions_test_() ->
    [?_assertMatch({error, {_, ext_records, {unknown_record, _}}}, angler:snippet(S)) || S <- [
        "P=get_person(), P.name.",
        "P=#person{address=#address{}}, A=P.address, A.city.",
        "P=Unknown, P.name.",
        "case ok of ok -> P=#person{} end, P.name.",
        "F=fun()->P=#person{}, P.name end, F().",
        "{P}={#person{}}, P.name.",
        "f(P=#person{}), P.name.",
        "P=(#person{}), P.name.",
        "P=?PERSON, P.name.",
        "P=#person{age=P.age}.",
        "_=#person{}, _.name."
    ]].

deduction_reset_test() ->
    ?assertMatch({error, {_, ext_records, {unknown_record, 'P'}}},
        angler:transpile("f(0)->P=#person{}, P.name; f(P)->P.name.")),
    ?assertMatch({error, {_, ext_records, {unknown_record, 'P'}}},
        angler:transpile("f()->P=#person{}, P.name. g(P)->P.name.")),
    ?assertMatch({ok, _}, angler:snippet("P=#person{},P.name.")),
    ?assertMatch({error, {_, ext_records, {unknown_record, 'P'}}}, angler:snippet("P.name.")).

deduction_identity_and_trivia_test() ->
    S = "f()->P=#person{}, Q=P, Q#person.name.",
    ?assertEqual({ok, S}, angler:transpile(S)),
    Bytes = <<239,187,191,"% caf",195,169,"\r\nP = % construction\r\n #person{}, Alias = P, Alias.name.">>,
    {ok, Out} = angler:snippet(Bytes),
    ?assertMatch(<<239,187,191,_/binary>>, Out),
    ?assertNotEqual(nomatch, binary:match(Out, <<"% construction\r\n">>)),
    ?assertNotEqual(nomatch, binary:match(Out, <<"Alias#person.name">>)),
    Latin1 = <<"% caf",233,"\r\nP=#person{}, P.name.">>,
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
