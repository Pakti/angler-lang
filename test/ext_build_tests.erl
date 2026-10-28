-module(ext_build_tests).
-include_lib("eunit/include/eunit.hrl").

api_test() ->
    Root = filename:join(
        "_build/test", "build-api-" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    In = filename:join(Root, "input"),
    Out = filename:join(Root, "output"),
    ok = filelib:ensure_path(In),
    try
        ok = file:write_file(filename:join(In, "a.erlx"), <<"-module(a). _export f()->ok.">>),
        Opts = #{input => In, output => Out},
        ?assertMatch({ok, #{written := 1, skipped := 0}, []}, angler:build(Opts)),
        ?assertMatch({ok, #{written := 0, skipped := 1}, []}, angler:build(Opts)),
        ok = file:write_file(filename:join(Out, "extra"), <<"keep">>),
        ?assertMatch({ok, _, [{_, {none, ext_build, extra_file}}]}, angler:build(Opts)),
        ?assertMatch(
            {ok, #{written := 1, deleted := 1}, []},
            angler:build(Opts#{clean => true, delete => true})
        ),
        ?assertNot(filelib:is_file(filename:join(Out, "extra")))
    after
        file:del_dir_r(Root)
    end.

missing_input_test() ->
    ?assertMatch(
        {error, {_, ext_build, missing_input}, []},
        angler:build(#{input => "_build/nonexistent-input", output => "_build/nonexistent-output"})
    ).
