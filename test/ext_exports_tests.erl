-module(ext_exports_tests).
-include_lib("eunit/include/eunit.hrl").

golden_test_() ->
    Cases = [
        {"-module(m).\n_export\nfoo() -> ok.\n",
         "-module(m).\n-export([foo/0]). \nfoo() -> ok.\n"},
        {"-module(m).\nhelper()->ok.\n_export\nfoo()->helper().",
         "-module(m).\n-export([foo/0]). helper()->ok.\n\nfoo()->helper()."},
        {"-module(m).\r\n_export % keep\r\n% between\r\nfoo()->ok. % eof",
         "-module(m).\r\n-export([foo/0]).  % keep\r\n% between\r\nfoo()->ok. % eof"},
        {"-module(m). _export foo()->ok. _export bar(X)->X.",
         "-module(m). -export([foo/0,bar/1]).  foo()->ok.  bar(X)->X."},
        {"-module(m). -export([foo/0]). _export foo()->ok.",
         "-module(m). -export([foo/0]).  foo()->ok."},
        {"-module(m). _export foo()->ok. -export([foo/0]).",
         "-module(m).  foo()->ok. -export([foo/0])."},
        {"-module(m). _export 'quoted name'()->ok.",
         "-module(m). -export(['quoted name'/0]).  'quoted name'()->ok."}
    ],
    [?_assertEqual(Expected, transpile(Source)) || {Source, Expected} <- Cases] ++
    [?_assertEqual(unicode:characters_to_binary(Expected),
                   transpile(unicode:characters_to_binary(Source)))
     || {Source, Expected} <- Cases].

unchanged_test_() ->
    Sources = ["", " \t\r\n% eof", "-module(m). f()->ok.",
        "-module(m). f()-> _export = ok, _export.",
        "-module(m). f()->fun(_export)->_export end.",
        "-module(m). % _export\nf()->\"_export\".",
        "-module(m). x_start()->ok.",
        "-module(m). '_export'()->ok.",
        "-module(m). -define(V, _export). f()->?V."],
    [?_assertEqual(Source, transpile(Source)) || Source <- Sources].

head_recognition_test_() ->
    Heads = [
        {"f()", "f/0"},
        {"f(X, Y)", "f/2"},
        {"f({X,Y}, [A,B|T], #{key := {V,W}}, <<N:8, Rest/binary>>)", "f/4"},
        {"f(#person{age = X}, (Y = {a,b}))", "f/2"},
        {"f(X) when is_integer(X), X > 0; is_atom(X)", "f/1"},
        {"'end'(X)", "'end'/1"}
    ],
    [?_assert(lists:prefix("-module(m). -export([" ++ Export ++ "]).",
                 transpile("-module(m). _export " ++ Head ++ " -> ok.")))
     || {Head, Export} <- Heads].

diagnostics_test_() ->
    Cases = [
        {"_export", expected_function},
        {"_export % eof", expected_function},
        {"_export.", expected_function},
        {"_export\n_export\nf()->ok.", expected_function},
        {"_export\n-spec f()->ok.\nf()->ok.", expected_function},
        {"_export\n-export([f/0]).\nf()->ok.", expected_function},
        {"_export\nfoo", expected_function},
        {"_export\nf(X,)->ok.", invalid_function_head},
        {"_export\nf(?ARGS)->ok.", invalid_function_head},
        {"-ifdef(FLAG).\n_export f()->ok.\n-endif.", conditional_export},
        {"-ifndef(FLAG).\n_export f()->ok.\n-endif.", conditional_export},
        {"-if(true).\n_export f()->ok.\n-endif.", conditional_export},
        {"-ifdef(FLAG).\n-else.\n_export f()->ok.\n-endif.", conditional_export}
    ],
    [?_test(begin
        {error, {Location, ext_exports, Reason}} = angler:transpile(Source),
        ?assertMatch({_, _}, Location),
        Tag = case Reason of {Name, _} -> Name; Name -> Name end,
        ?assertEqual(Expected, Tag),
        ?assert(is_list(ext_exports:format_error(Reason)))
    end) || {Source, Expected} <- Cases].

error_location_test() ->
    ?assertEqual({error, {{3, 3}, ext_exports, expected_function}},
                 angler:transpile("% leading\n\n  _export\n-module(m).")),
    ?assertMatch({error, {_, erl_scan, _}}, angler:transpile("\"unterminated")),
    ?assertEqual({error, {invalid_encoding, utf8}}, angler:transpile(<<255>>)).

encoding_test() ->
    Latin1 = <<"-module(m). % caf", 233, "\r\n_export f()->ok.">>,
    {ok, Output} = angler:transpile(Latin1, latin1),
    ?assertEqual(<<"-module(m). % caf", 233,
                   "\r\n-export([f/0]).  f()->ok.">>, Output),
    Utf8 = unicode:characters_to_binary("-module(m). _export '" ++
                                       [16#3bb] ++ "'()->ok."),
    Bom = <<239, 187, 191, Utf8/binary>>,
    Transformed = transpile(Bom),
    ?assertMatch(<<239, 187, 191, _/binary>>, Transformed),
    ?assertEqual(Transformed, transpile(Transformed)).

%% Compile with warnings as errors and actually call the exported functions.
compiler_test_() ->
    Fixtures = [
        {"-module(angler_exports_fixture).\n"
         "helper()->ok.\n"
         "_export\nrun()->helper().\n"
         "_export\nchoose(0)->zero; choose(X) when is_integer(X)->{number,X}.\n",
         [], fun() ->
             ?assertEqual(ok, angler_exports_fixture:run()),
             ?assertEqual(zero, angler_exports_fixture:choose(0)),
             ?assertEqual({number, 3}, angler_exports_fixture:choose(3)),
             ?assertNot(erlang:function_exported(angler_exports_fixture, helper, 0))
         end},
        {"-module(angler_exports_fixture).\n"
         "-export([run/0]).\n"
         "-include(\"roundtrip_fixture.hrl\").\n"
         "_export % keep original locations\n"
         "run()-> P0=#person{}, P=?NEXT(P0), {?LINE,P#person.age}.\n",
         [], fun() -> ?assertEqual({5,42}, angler_exports_fixture:run()) end},
        {"-module(angler_exports_fixture).\n"
         "-define(VALUE, 42).\n"
         "_export\nrun()-> F=fun(X)->case X of 1->?VALUE; _->error end end, F(1).",
         [], fun() -> ?assertEqual(42, angler_exports_fixture:run()) end},
        {"-module(angler_exports_fixture).\n"
         "-export([other/0]).\n"
         "other()->ok.\n"
         "_export run()->{?LINE, other()}.\n",
         [], fun() -> ?assertEqual({4,ok}, angler_exports_fixture:run()) end},
        {"-module(angler_exports_fixture).\n"
         "-ifdef(FLAG).\nhelper()->yes.\n-else.\nhelper()->no.\n-endif.\n"
         "_export run()->helper().",
         [], fun() -> ?assertEqual(no, angler_exports_fixture:run()) end},
        {"-module(angler_exports_fixture).\n"
         "-ifdef(FLAG).\nhelper()->yes.\n-else.\nhelper()->no.\n-endif.\n"
         "_export run()->helper().",
         [{d, 'FLAG'}], fun() -> ?assertEqual(yes, angler_exports_fixture:run()) end},
        {"-module(angler_exports_fixture).\n"
          "-include(\"export_helpers.hrl\").\n"
          "_export run()->included().",
          [], fun() -> ?assertEqual(ok, angler_exports_fixture:run()) end}
    ],
    [?_test(compile_and_run(Source, Options, Check)) || {Source, Options, Check} <- Fixtures].

compile_and_run(Source, Options, Check) ->
    Output = transpile(Source),
    ?assertEqual(Output, transpile(Output)),
    ?assertEqual(length([C || C <- Source, C =:= $\n]),
                 length([C || C <- Output, C =:= $\n])),
    Path = "_build/test/angler_exports_fixture.erl",
    ok = file:write_file(Path, Output),
    try
        {ok, angler_exports_fixture, Beam, []} = compile:file(Path,
            [binary, warnings_as_errors, return_errors, return_warnings,
             {i, "test/fixtures"} | Options]),
        {module, angler_exports_fixture} =
            code:load_binary(angler_exports_fixture, Path, Beam),
        Check()
    after
        code:purge(angler_exports_fixture),
        code:delete(angler_exports_fixture),
        file:delete(Path)
    end.

transpile(Source) ->
    {ok, Output} = angler:transpile(Source),
    Output.
