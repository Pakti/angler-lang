%% Explicit annotations and limited local record-name deduction. No type checker.
-module(ext_records).
-export([rewrite/2, format_error/1]).

rewrite(Document, Mode) ->
    try
        Edits =
            case Mode of
                module -> lists:foldl(fun function/2, #{}, ext_types:functions(Document));
                snippet -> scan(ext_scan:significant(Document), #{}, #{}, start)
            end,
        {ok, ext_syntax:apply(Document, Edits)}
    catch
        throw:{record_error, Location, Reason} -> {error, {Location, ?MODULE, Reason}};
        throw:{export_error, Location, Reason} ->
            {error, {Location, ext_exports, Reason}};
        throw:{syntax_error, Location, Reason} -> {error, {Location, ext_types, Reason}}
    end.

function(#{clauses := Clauses}, Edits) ->
    lists:foldl(
        fun(C, Acc) ->
            Environment = lists:foldl(fun header_binding/2, #{}, maps:get(args, C)),
            GuardEdits = scan(maps:get(guard, C), Environment, Acc, start),
            scan(maps:get(body, C), Environment, GuardEdits, start)
        end,
        Edits,
        Clauses
    ).

header_binding(#{annotation := none}, Env) ->
    Env;
header_binding(#{pattern := [Variable], annotation := Annotation}, Env) ->
    bind(Variable, Annotation, Env).

bind({_, {var, _, '_'}}, _, Env) ->
    Env;
bind({_, {var, _, Name}} = Variable, #{ast := Ast}, Env) ->
    Normal = erl_parse:map_anno(fun(_) -> 0 end, Ast),
    Record =
        case Ast of
            {type, _, record, [{atom, _, RecordName} | _]} -> RecordName;
            _ -> none
        end,
    Location = erl_scan:location(element(2, Variable)),
    case maps:find(Name, Env) of
        {ok, {Other, OldRecord, Earlier, Origin}} ->
            Compatible =
                Other =:= Normal orelse
                    (Origin =:= deduced andalso Record =/= none andalso OldRecord =:= Record),
            case Compatible of
                true -> Env#{Name => {Normal, Record, Location, explicit}};
                false -> fail(Variable, {conflicting_annotation, Name, Earlier})
            end;
        error ->
            Env#{Name => {Normal, Record, Location, explicit}}
    end.

%% Only a complete, direct binding at the top-level expression sequence
%% may contribute a deduction. Walking its RHS uses the earlier environment.
scan(Entries, Env, Edits, Prev) ->
    {Result, _} = lists:foldl(
        fun(Expression, {Acc, Before}) ->
            {AfterEdits, After} = walk(Expression, Before, Acc, Prev),
            {AfterEdits, deduce(Expression, Before, After)}
        end,
        {Edits, Env},
        ext_syntax:split(Entries, ',')
    ),
    Result.

deduce(Expression, Before, After) ->
    case binding(without_dot(Expression)) of
        {Variable, RHS} ->
            case record_value(RHS, Before) of
                none -> After;
                Record -> bind_deduced(Variable, Record, After)
            end;
        none ->
            After
    end.
without_dot(Entries) ->
    case lists:reverse(Entries) of
        [{_, {dot, _}} | Rest] -> lists:reverse(Rest);
        _ -> Entries
    end.
binding([{_, {var, _, _}} = Variable, {_, {'=', _}} | RHS]) ->
    {Variable, RHS};
binding([{_, {var, _, _}} = Variable, {_, {'::', _}} | Rest]) ->
    case ext_syntax:take(Rest, '=') of
        {_, [{_, {'=', _}} | RHS]} -> {Variable, RHS};
        _ -> none
    end;
binding(_) ->
    none.

record_value([{_, {'#', _}}, {_, {atom, _, Name}}, {_, {'{', _}} | Fields], _) ->
    complete_record(Fields, Name);
record_value(
    [
        {_, {var, _, _}},
        {_, {'#', _}},
        {_, {atom, _, Name}},
        {_, {'{', _}}
        | Fields
    ],
    _
) ->
    complete_record(Fields, Name);
record_value([{_, {var, _, Name}}, {_, {'{', _}} | Fields], Env) ->
    complete_record(Fields, known_record(Name, Env));
record_value([{_, {var, _, Name}}], Env) ->
    known_record(Name, Env);
record_value(_, _) ->
    none.
complete_record(Fields, Record) ->
    case ext_syntax:take(Fields, '}') of
        {_, [{_, {'}', _}}]} -> Record;
        _ -> none
    end.
known_record(Name, Env) ->
    case maps:find(Name, Env) of
        {ok, {_, Record, _, _}} -> Record;
        error -> none
    end.
bind_deduced({_, {var, _, '_'}}, _, Env) ->
    Env;
bind_deduced({_, {var, _, Name}} = Variable, Record, Env) ->
    case maps:find(Name, Env) of
        {ok, {_, Record, _, _}} ->
            Env;
        {ok, {_, _, Earlier, _}} ->
            fail(Variable, {conflicting_annotation, Name, Earlier});
        error ->
            Normal = {type, 0, record, [{atom, 0, Record}]},
            Location = erl_scan:location(element(2, Variable)),
            Env#{Name => {Normal, Record, Location, deduced}}
    end.

walk([], Env, Edits, _) ->
    {Edits, Env};
%% Macro names are lexically variables too. Let the preprocessor handle
%% ordinary constructs such as P?RECORD.age, where ?RECORD expands to #person.
walk([{_, {var, _, _}} | Rest], Env, Edits, '?') ->
    walk(Rest, Env, Edits, macro);
walk([{_, {var, _, _}} = Variable, {_, {'::', _}} = Colon | Rest], Env, Edits, Prev) ->
    case
        lists:member(Prev, [
            start,
            ',',
            ';',
            '->',
            'begin',
            'of',
            'else',
            'try',
            'after',
            'catch',
            'maybe',
            '('
        ])
    of
        false -> fail(Colon, unsupported_local_pattern);
        true -> ok
    end,
    {Type, After} = ext_syntax:take(Rest, '='),
    case After of
        [{_, {'=', _}} | _] ->
            Annotation = ext_types:annotation(Colon, Type),
            NextEnv = bind(Variable, Annotation, Env),
            NextEdits = ext_syntax:remove(maps:get(remove, Annotation), Edits),
            walk(After, NextEnv, NextEdits, var);
        _ ->
            fail(Colon, expected_binding)
    end;
walk(
    [
        {_, {var, _, Name}} = Variable,
        {I, {'.', _} = Dot},
        {_, {atom, _, _}} = Field
        | Rest
    ],
    Env,
    Edits,
    _
) ->
    Record = record(Variable, Name, Env),
    case Rest of
        [{_, {'.', _}} = Next, {_, {atom, _, _}} | _] -> fail(Next, chained_field);
        _ -> ok
    end,
    Prefix = record_prefix(Record, erl_scan:location(Dot)),
    walk(Rest, Env, Edits#{I => Prefix ++ [Dot]}, element(1, element(2, Field)));
walk([{_, {var, _, Name}} = Variable, {I, {'{', _} = Brace} | Rest], Env, Edits, _) ->
    Record = record(Variable, Name, Env),
    Prefix = record_prefix(Record, erl_scan:location(Brace)),
    walk(Rest, Env, Edits#{I => Prefix ++ [Brace]}, '{');
walk([{_, Token} | Rest], Env, Edits, _) ->
    walk(Rest, Env, Edits, erl_scan:category(Token)).

record(Variable, Name, Env) ->
    case maps:find(Name, Env) of
        {ok, {_, Record, _, _}} when Record =/= none -> Record;
        _ -> fail(Variable, {unknown_record, Name})
    end.
record_prefix(Name, Location) -> ext_syntax:generated(io_lib:format("#~tp", [Name]), Location).
fail({_, Token}, Reason) -> throw({record_error, erl_scan:location(Token), Reason}).

format_error({unknown_record, Name}) ->
    io_lib:format(
        "~tp needs an explicit record annotation or a supported earlier record binding before abbreviated access or update",
        [Name]
    );
format_error({conflicting_annotation, Name, Earlier}) ->
    io_lib:format("conflicting annotation or deduced record for ~tp; earlier binding at ~p", [
        Name, Earlier
    ]);
format_error(unsupported_local_pattern) ->
    "local annotations require a simple variable binding, not a nested pattern";
format_error(expected_binding) ->
    "local annotations must have the form Variable :: Type = Expression";
format_error(chained_field) ->
    "nested record access needs a separately annotated intermediate variable".
