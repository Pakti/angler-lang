-module(ext_roundtrip_tests).
-include_lib("eunit/include/eunit.hrl").

roundtrip_test_() ->
    Sources = [
        "", " ", "\t\r\n\n  ", "% no newline", "% comment\r\n",
        "ok.", "ok. ", "ok.\n", "ok.\r\n", "ok.\r",
        "ok. % trailing comment", "ok.\n\n% final comment\n  ",
        "-module(example).\n-export([f/0]).\nf() -> ok.\n",
        "f(X) when is_integer(X) -> X + 16#ff;\nf(_) -> 1.00e+02.\n",
        "f() -> {'quoted atom', $\\n, $ , <<1, 2>>, \"P.age _export ::\"}.",
        "%% P.age _export ::\nf() -> \"escaped \\\" quote\".\n",
        "f() -> fun(X) -> case X of ok -> ok; _ -> error end end.\n",
        "f() -> \"caf" ++ [16#e9, 16#1f41f] ++ "\".\n"
    ],
    [?_assertEqual(Source, roundtrip(Source)) || Source <- Sources] ++
    [?_assertEqual(Bytes, roundtrip(Bytes)) || Source <- Sources,
        Bytes <- [unicode:characters_to_binary(Source)]].

encoding_test() ->
    Utf8 = unicode:characters_to_binary("% caf" ++ [16#e9] ++ "\r\nf() -> ok."),
    Bom = <<239, 187, 191, Utf8/binary>>,
    ?assertEqual(Bom, roundtrip(Bom)),
    ?assertEqual(<<239, 187, 191>>, roundtrip(<<239, 187, 191>>)),
    Latin1 = <<"%% coding: latin-1\r\n% caf", 233, "\r\nf() -> ok.">>,
    {ok, LatinDoc} = ext_scan:scan(Latin1, latin1),
    ?assertEqual(Latin1, ext_emit:emit(LatinDoc)),
    ?assertEqual({error, {invalid_encoding, utf8}}, ext_scan:scan(Latin1)),
    ?assertEqual({error, {invalid_encoding, utf8}}, ext_scan:scan(<<240, 159>>)).

token_views_test() ->
    {ok, Document} = ext_scan:scan(" \t% comment\nfoo ( X ) .\n"),
    Tokens = ext_scan:tokens(Document),
    Significant = ext_scan:significant(Document),
    ?assertEqual([atom, '(', var, ')', dot],
                 [erl_scan:category(T) || {_, T} <- Significant]),
    lists:foreach(fun({Index, Token}) ->
        ?assertEqual(Token, lists:nth(Index, Tokens)),
        ?assert(is_list(erl_scan:text(Token)))
    end, Significant),
    ?assertEqual({2, 1}, erl_scan:location(element(2, hd(Significant)))),
    {ok, Empty} = ext_scan:scan(<<>>),
    ?assertEqual([], ext_scan:significant(Empty)).

scanner_error_test() ->
    lists:foreach(fun(Source) ->
        {error, {Location, erl_scan, Description}} = ext_scan:scan(Source),
        ?assertMatch({_, _}, Location),
        ?assert(is_list(erl_scan:format_error(Description)))
    end, ["f() -> \"unterminated", "'unterminated", "16#zz."]).

%% Includes, macros and ?LINE go through the ordinary compiler after emission.
compiler_acceptance_test() ->
    {ok, Source} = file:read_file("test/fixtures/roundtrip_fixture.erl"),
    Output = roundtrip(Source),
    Path = "_build/test/roundtrip_fixture.erl",
    ok = file:write_file(Path, Output),
    try
        {ok, roundtrip_fixture, Beam} =
            compile:file(Path, [binary, warnings_as_errors, return_errors,
                                {i, "test/fixtures"}]),
        {module, roundtrip_fixture} = code:load_binary(roundtrip_fixture, Path, Beam),
        ?assertEqual({7, 42}, roundtrip_fixture:run())
    after
        code:purge(roundtrip_fixture),
        code:delete(roundtrip_fixture),
        file:delete(Path)
    end.

repository_sources_test_() ->
    Paths = filelib:wildcard("src/*.erl") ++ filelib:wildcard("test/*.erl") ++
            filelib:wildcard("test/fixtures/*"),
    [{Path, fun() ->
        {ok, Source} = file:read_file(Path),
        Output = roundtrip(Source),
        ?assertEqual(Source, Output),
        ?assertEqual(Output, roundtrip(Output))
    end} || Path <- Paths].

roundtrip(Source) ->
    {ok, Document} = ext_scan:scan(Source),
    ext_emit:emit(Document).
