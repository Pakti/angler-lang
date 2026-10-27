%% Inline head annotations and specification generation, without preprocessing.
-module(ext_types).
-export([rewrite/1, functions/1, annotation/2, format_error/1]).

rewrite(Document) ->
    try
        Functions = functions(Document, true),
        Explicit = explicit_specs(ext_forms:forms(Document)),
        {Edits, Warnings} = lists:foldl(fun(F, Acc) -> rewrite_function(F, Explicit, Acc) end,
                                      {#{}, []}, Functions),
        {ok, ext_syntax:apply(Document, Edits), lists:reverse(Warnings)}
    catch throw:{syntax_error, Location, Reason} -> {error, {Location, ?MODULE, Reason}} end.

functions(Document) -> functions(Document, false).
functions(Document, OnlyAnnotated) ->
    lists:filtermap(fun(Form) ->
        Bare = case Form of [{_, {var, _, '_export'}} | Rest] -> Rest; _ -> Form end,
        case Bare of
            [{_, {atom, _, Name}}, {_, {'(', _}} | _] ->
                Clauses = [clause(C) || C <- ext_syntax:clauses(Bare)],
                [First | _] = Clauses,
                Arity = length(maps:get(args, First)),
            lists:foreach(fun(C) ->
                    case {maps:get(name, C), length(maps:get(args, C))} of
                        {Name, Arity} -> ok;
                        _ -> ext_syntax:error(hd(maps:get(entries, C)), inconsistent_clauses)
                    end
                end, Clauses),
                {true, #{key => {Name, Arity}, clauses => Clauses, start => hd(Form)}};
            _ -> false
        end
    end, [F || F <- ext_forms:forms(Document), not OnlyAnnotated orelse
               lists:any(fun({_, T}) -> erl_scan:category(T) =:= '::' end, F)]).

clause([{_, {atom, _, Name}}, {_, {'(', _}} | Rest] = Entries) ->
    {ArgTokens, AfterArgs} = ext_syntax:take(Rest, ')'),
    case AfterArgs of
        [{_, {')', _}} | Tail] ->
            Args = case ArgTokens of [] -> []; _ -> [argument(A) || A <- ext_syntax:split(ArgTokens, ',')] end,
            {BeforeArrow, ArrowBody} = ext_syntax:take(Tail, '->'),
            case ArrowBody of
                [{_, {'->', _}} | Body] ->
                    {Return, Guard} = ext_syntax:take(BeforeArrow, 'when'),
                    Ret = case Return of
                        [] -> none;
                        [{_, {'::', _}} = Colon | Type] -> annotation(Colon, Type);
                        _ -> ext_syntax:error(hd(Return), invalid_return_annotation)
                    end,
                    #{name => Name, args => Args, return => Ret, guard => Guard,
                      body => Body, entries => Entries};
                _ -> ext_syntax:error(hd(Entries), expected_arrow)
            end;
        _ -> ext_syntax:error(hd(Entries), invalid_function_head)
    end;
clause(Entries) -> ext_syntax:error(hd(Entries), inconsistent_clauses).

argument(Entries) ->
    {Pattern, Annotated} = ext_syntax:take(Entries, '::'),
    Ann = case Annotated of
        [] -> none;
        [Colon | Type] ->
            %% V1 deliberately limits annotated patterns to simple variables.
            case Pattern of
                [{_, {var, _, _}}] -> annotation(Colon, Type);
                _ -> ext_syntax:error(Colon, unsupported_pattern)
            end
    end,
    #{pattern => Pattern, annotation => Ann}.

annotation(Colon, []) -> ext_syntax:error(Colon, empty_type);
annotation(Colon, Type) ->
    Text = ext_syntax:text(Type),
    Tokens = ext_syntax:generated(["-type angler_annotation() :: ", Text, ". "], {1, 1}),
    Significant = [T || T <- Tokens, erl_scan:category(T) =/= white_space,
                                   erl_scan:category(T) =/= comment],
    case erl_parse:parse_form(Significant) of
        {ok, {attribute, _, type, {angler_annotation, Ast, []}}} ->
            #{type => Type, ast => Ast, remove => [Colon | Type], text => Text};
        {error, _} -> ext_syntax:error(Colon, invalid_type)
    end.

explicit_specs(Forms) ->
    lists:filtermap(fun(Form) ->
        case Form of
            [{_, {'-', _}}, {_, {atom, _, spec}} | _] ->
                case erl_parse:parse_form([T || {_, T} <- Form]) of
                    {ok, {attribute, Anno, spec, {Key, _}}} -> {true, {spec_key(Key), erl_anno:location(Anno)}};
                    _ -> false
                end;
            _ -> false
        end
    end, Forms).

spec_key({_Module, Name, Arity}) -> {Name, Arity};
spec_key(Key) -> Key.

rewrite_function(#{key := Key, clauses := Clauses, start := Start}, Explicit, {Edits, Warnings}) ->
    Annotations = lists:append([annotations(C) || C <- Clauses]),
    case Annotations of
        [] -> {Edits, Warnings};
        [First | _] ->
            case lists:keyfind(Key, 1, Explicit) of
                {Key, Location} -> ext_syntax:error(hd(maps:get(remove, First)), {spec_conflict, Key, Location});
                false -> ok
            end,
            lists:foreach(fun(C) ->
                lists:foreach(fun(Arg) ->
                    lists:foreach(fun({_, T} = Entry) ->
                        case erl_scan:category(T) of
                            '?' -> ext_syntax:error(Entry, macro_argument);
                            _ -> ok
                        end
                    end, maps:get(pattern, Arg))
                end, maps:get(args, C))
            end, Clauses),
            Clean = lists:foldl(fun(A, Acc) -> ext_syntax:remove(maps:get(remove, A), Acc) end, Edits, Annotations),
            HasTypes = lists:any(fun(A) -> not is_any(A) end, Annotations),
            case HasTypes of
                false -> {Clean, Warnings};
                true ->
                    {Name, _} = Key,
                    [Signature | Others] = [signature(C) || C <- Clauses],
                    Spec = ["-spec ", io_lib:format("~tp", [Name]), Signature,
                            [["; ", S] || S <- Others], ". "],
                    {I, T} = Start,
                    Generated = ext_syntax:generated(Spec, erl_scan:location(T)),
                    New = Clean#{I => Generated ++ maps:get(I, Clean, [T])},
                    Partial = length(Clauses) > 1 andalso lists:any(fun incomplete/1, Clauses),
                    Warn = case Partial of
                        true -> [{erl_scan:location(T), ?MODULE, {partial_overload, Key}} | Warnings];
                        false -> Warnings
                    end,
                    {New, Warn}
            end
    end.

annotations(C) -> [A || A <- [maps:get(annotation, Arg) || Arg <- maps:get(args, C)] ++
                               [maps:get(return, C)], A =/= none].
is_any(#{ast := {type, _, any, []}}) -> true;
is_any(_) -> false.
type_text(none) -> "any()";
type_text(#{text := Text}) -> Text.
signature(C) -> ["(", lists:join(", ", [type_text(maps:get(annotation, A)) || A <- maps:get(args, C)]),
                 ") -> ", type_text(maps:get(return, C))].
incomplete(C) -> maps:get(return, C) =:= none orelse
    lists:any(fun(A) -> maps:get(annotation, A) =:= none end, maps:get(args, C)).

format_error({spec_conflict, {Name, Arity}, Location}) ->
    io_lib:format("inline annotations for ~tp/~B conflict with explicit -spec at ~p; remove one", [Name, Arity, Location]);
format_error({partial_overload, {Name, Arity}}) ->
    io_lib:format("~tp/~B has a partially annotated overload; any() fallbacks may overlap; use an explicit spec for precise contracts", [Name, Arity]);
format_error(macro_argument) -> "macro-expanded argument patterns cannot determine a generated spec arity; use an explicit spec";
format_error(unsupported_pattern) -> "only simple variable patterns may carry inline argument annotations";
format_error(invalid_type) -> "invalid or unsupported Erlang type annotation (macros are not expanded)";
format_error(empty_type) -> "expected a type after ::";
format_error(invalid_return_annotation) -> "expected :: Type or a guard after function arguments";
format_error(invalid_function_head) -> "invalid function head";
format_error(expected_arrow) -> "expected -> after function head";
format_error(inconsistent_clauses) -> "function clauses must have the same name and arity".
