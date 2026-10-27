%% Explicit annotation environments. No field inference or lexical shadowing.
-module(ext_records).
-export([rewrite/2, format_error/1]).

rewrite(Document, Mode) ->
    try
        Edits = case Mode of
            module -> lists:foldl(fun function/2, #{}, ext_types:functions(Document));
            snippet -> scan(ext_scan:significant(Document), #{}, #{}, start)
        end,
        {ok, ext_syntax:apply(Document, Edits)}
    catch
        throw:{record_error, Location, Reason} -> {error, {Location, ?MODULE, Reason}};
        throw:{syntax_error, Location, Reason} -> {error, {Location, ext_types, Reason}}
    end.

function(#{clauses := Clauses}, Edits) ->
    lists:foldl(fun(C, Acc) ->
        Environment = lists:foldl(fun header_binding/2, #{}, maps:get(args, C)),
        GuardEdits = scan(maps:get(guard, C), Environment, Acc, start),
        scan(maps:get(body, C), Environment, GuardEdits, start)
    end, Edits, Clauses).

header_binding(#{annotation := none}, Env) -> Env;
header_binding(#{pattern := [Variable], annotation := Annotation}, Env) ->
    bind(Variable, Annotation, Env).

bind({_, {var, _, '_'}}, _, Env) -> Env;
bind({_, {var, _, Name}} = Variable, #{ast := Ast}, Env) ->
    Normal = erl_parse:map_anno(fun(_) -> 0 end, Ast),
    Record = case Ast of
        {type, _, record, [{atom, _, RecordName} | _]} -> RecordName;
        _ -> none
    end,
    Location = erl_scan:location(element(2, Variable)),
    case maps:find(Name, Env) of
        {ok, {Other, _, Earlier}} when Other =/= Normal ->
            fail(Variable, {conflicting_annotation, Name, Earlier});
        _ -> Env#{Name => {Normal, Record, Location}}
    end.

scan([], _, Edits, _) -> Edits;
%% Macro names are lexically variables too. Let the preprocessor handle
%% ordinary constructs such as P?RECORD.age, where ?RECORD expands to #person.
scan([{_, {var, _, _}} | Rest], Env, Edits, '?') ->
    scan(Rest, Env, Edits, macro);
scan([{_, {var, _, _}} = Variable, {_, {'::', _}} = Colon | Rest], Env, Edits, Prev) ->
    case lists:member(Prev, [start, ',', ';', '->', 'begin', 'of', 'else',
                             'try', 'after', 'catch', 'maybe', '(']) of
        false -> fail(Colon, unsupported_local_pattern);
        true -> ok
    end,
    {Type, After} = ext_syntax:take(Rest, '='),
    case After of
        [{_, {'=', _}} | _] ->
            Annotation = ext_types:annotation(Colon, Type),
            NextEnv = bind(Variable, Annotation, Env),
            NextEdits = ext_syntax:remove(maps:get(remove, Annotation), Edits),
            scan(After, NextEnv, NextEdits, var);
        _ -> fail(Colon, expected_binding)
    end;
scan([{_, {var, _, Name}} = Variable, {I, {'.', _} = Dot},
      {_, {atom, _, _}} = Field | Rest], Env, Edits, _) ->
    Record = record(Variable, Name, Env),
    case Rest of
        [{_, {'.', _}} = Next, {_, {atom, _, _}} | _] -> fail(Next, chained_field);
        _ -> ok
    end,
    Prefix = record_prefix(Record, erl_scan:location(Dot)),
    scan(Rest, Env, Edits#{I => Prefix ++ [Dot]}, element(1, element(2, Field)));
scan([{_, {var, _, Name}} = Variable, {I, {'{', _} = Brace} | Rest], Env, Edits, _) ->
    Record = record(Variable, Name, Env),
    Prefix = record_prefix(Record, erl_scan:location(Brace)),
    scan(Rest, Env, Edits#{I => Prefix ++ [Brace]}, '{');
scan([{_, Token} | Rest], Env, Edits, _) ->
    scan(Rest, Env, Edits, erl_scan:category(Token)).

record(Variable, Name, Env) ->
    case maps:find(Name, Env) of
        {ok, {_, Record, _}} when Record =/= none -> Record;
        _ -> fail(Variable, {unknown_record, Name})
    end.
record_prefix(Name, Location) -> ext_syntax:generated(io_lib:format("#~tp", [Name]), Location).
fail({_, Token}, Reason) -> throw({record_error, erl_scan:location(Token), Reason}).

format_error({unknown_record, Name}) ->
    io_lib:format("~tp needs an explicit record annotation before abbreviated access or update", [Name]);
format_error({conflicting_annotation, Name, Earlier}) ->
    io_lib:format("conflicting annotation for ~tp; earlier annotation at ~p", [Name, Earlier]);
format_error(unsupported_local_pattern) ->
    "local annotations require a simple variable binding, not a nested pattern";
format_error(expected_binding) -> "local annotations must have the form Variable :: Type = Expression";
format_error(chained_field) -> "nested record access needs a separately annotated intermediate variable".
