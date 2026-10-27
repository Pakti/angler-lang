%% Expand top-level _export directives without reformatting existing tokens.
-module(ext_exports).
-export([rewrite/1, format_error/1]).

-spec rewrite(ext_scan:document()) ->
    {ok, ext_scan:document()} | {error, term()}.
rewrite(Document) ->
    Forms = contexts(ext_forms:forms(Document), [], []),
    Existing = existing_exports(Forms),
    case replacements(Forms, Existing, #{}, []) of
        {ok, Removed, Generated} ->
            Replacements = insert_exports(Forms, Removed, Generated),
            Tokens = replace(ext_scan:tokens(Document), 1, Replacements),
            {ok, Document#{tokens := Tokens}};
        Error -> Error
    end.

replacements([], _, Replacements, Generated) ->
    {ok, Replacements, lists:reverse(Generated)};
replacements([{Context, [{Index, {var, _, '_export'} = Directive} | Rest]} | Forms],
             Exports, Replacements, Generated) ->
    case export_function(Context, Rest) of
        {ok, Function} ->
            NextGenerated = case already_exported(Function, Exports) of
                true -> Generated;
                false -> [Function | Generated]
            end,
            replacements(Forms, [{Context, Function} | Exports],
                         Replacements#{Index => []}, NextGenerated);
        {error, Reason} ->
            {error, {erl_scan:location(Directive), ?MODULE, Reason}}
    end;
replacements([_ | Forms], Exports, Replacements, Generated) ->
    replacements(Forms, Exports, Replacements, Generated).

export_function([], Form) -> ext_forms:function(Form);
export_function(_, _) -> {error, conditional_export}.

insert_exports(_, Replacements, []) -> Replacements;
insert_exports(Forms, Replacements, Functions) ->
    %% Prefer immediately after -module, before includes that may themselves
    %% contain functions. For module-less input, use the first definition.
    %% No newlines: ?LINE and existing trivia survive.
    [{Index, Token} | _] = insertion_point(Forms, Forms),
    Replacement = maps:get(Index, Replacements, [Token]),
    Replacements#{Index => export_tokens(Functions, erl_scan:location(Token)) ++
                           Replacement}.

insertion_point([{_, Form}, {_, Next} | Rest], All) ->
    case erl_parse:parse_form([T || {_, T} <- Form]) of
        {ok, {attribute, _, module, _}} -> Next;
        _ -> insertion_point([{none, Next} | Rest], All)
    end;
insertion_point(_, All) -> first_definition(All, All).

first_definition([{_, [{_, {'-', _}} | _]} | Rest], All) ->
    first_definition(Rest, All);
first_definition([{[], Form} | _], _) -> Form;
first_definition([{[{Start, _} | _], _} | _], All) ->
    %% Do not accidentally put an unconditional export inside the branch
    %% containing the first (unmarked) function.
    hd([Form || {_, [{Index, _} | _] = Form} <- All, Index =:= Start]).

export_tokens(Functions, Location) ->
    Entries = [io_lib:format("~tp/~B", [Name, Arity]) || {Name, Arity} <- Functions],
    %% A terminating dot must be followed by whitespace when another form
    %% immediately follows it. The separator adds no source lines.
    Text = lists:flatten(["-export([", lists:join(",", Entries), "]). "]),
    {ok, Tokens, _} = erl_scan:string(Text, Location, [text]),
    Tokens.

replace([], _, _) -> [];
replace([Token | Rest], Index, Replacements) ->
    maps:get(Index, Replacements, [Token]) ++ replace(Rest, Index + 1, Replacements).

existing_exports(Forms) ->
    lists:flatmap(fun({Context, Form}) ->
        case attribute(Form) of
            {export, _} -> literal_exports(Context, Form);
            _ -> []
        end
    end, Forms).

literal_exports(Context, Form) ->
    case erl_parse:parse_form([T || {_, T} <- Form]) of
        {ok, {attribute, _, export, Functions}} ->
            [{Context, Function} || Function <- Functions];
        _ -> []
    end.

already_exported(Function, Exports) -> lists:member({[], Function}, Exports).

%% Detect conditional directives without evaluating macros. Existing exports
%% in conditional branches must not suppress an unconditional export.
contexts([], _, Acc) -> lists:reverse(Acc);
contexts([Form | Rest], Stack, Acc) ->
    Context = lists:reverse(Stack),
    NextStack = case attribute(Form) of
        {Kind, Index} when Kind =:= ifdef; Kind =:= ifndef; Kind =:= 'if' ->
            [{Index, Index} | Stack];
        {Kind, Index} when Kind =:= 'else'; Kind =:= elif ->
            case Stack of
                [{Start, _} | Tail] -> [{Start, Index} | Tail];
                [] -> []
            end;
        {endif, _} -> case Stack of [_ | Tail] -> Tail; [] -> [] end;
        _ -> Stack
    end,
    contexts(Rest, NextStack, [{Context, Form} | Acc]).

attribute([{Index, {'-', _}}, {_, Token} | _]) ->
    Name = case Token of
        {atom, _, Atom} -> Atom;
        {Keyword, _} -> Keyword;
        _ -> undefined
    end,
    {Name, Index};
attribute(_) -> none.

-spec format_error(term()) -> string().
format_error(expected_function) ->
    "_export must be followed by a function, with only comments or whitespace between";
format_error(conditional_export) ->
    "_export inside preprocessor conditionals is not supported; use a standard -export attribute";
format_error({invalid_function_head, {_, Module, Reason}}) ->
    lists:flatten(["invalid or unsupported function head after _export: ",
                   Module:format_error(Reason)]).
