%% Expand top-level _export directives without reformatting existing tokens.
-module(ext_exports).
-export([rewrite/1, directive/1, format_error/1]).

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
replacements([{Context, Form} | Forms], Exports, Replacements, Generated) ->
    case directive(Form) of
        {ok, Tag, Removed, Rest} ->
            Directive = element(2, hd(Removed)),
            case export_function(Context, Rest) of
                {ok, Function} ->
                    NextGenerated = case already_exported(Function, Exports) of
                        true -> Generated;
                        false -> [{Tag, Function} | Generated]
                    end,
                    Edits = ext_syntax:remove(Removed, Replacements),
                    replacements(Forms, [{Context, Function} | Exports], Edits, NextGenerated);
                {error, Reason} -> {error, {erl_scan:location(Directive), ?MODULE, Reason}}
            end;
        none -> replacements(Forms, Exports, Replacements, Generated);
        Error -> Error
    end.

%% Shared with the type/record passes, which must see the actual function head.
directive([{_, {var, _, '_export'}} = Marker | Rest]) ->
    case Rest of
        [{_, {'(', _}} = Open, {_, {atom, _, Tag}} = Atom, {_, {')', _}} = Close | Function] ->
            {ok, {tag, Tag}, [Marker, Open, Atom, Close], Function};
        [{_, {'(', _}} | _] ->
            {error, {erl_scan:location(element(2, Marker)), ?MODULE, invalid_tag}};
        _ -> {ok, none, [Marker], Rest}
    end;
directive(_) -> none.

export_function([], Form) -> ext_forms:function(Form);
export_function(_, _) -> {error, conditional_export}.

insert_exports(_, Replacements, []) -> Replacements;
insert_exports(Forms, Replacements, Functions) ->
    %% Prefer immediately after -module, before includes that may themselves
    %% contain functions. For module-less input, use the first definition.
    %% Separate generated groups from surrounding forms and each other.
    [{Index, Token} | _] = insertion_point(Forms, Forms),
    Replacement = maps:get(Index, Replacements, [Token]),
    Tags = lists:uniq([Tag || {Tag, _} <- Functions]),
    Groups = [group_tokens(Tag, [F || {T, F} <- Functions, T =:= Tag],
                           erl_scan:location(Token)) || Tag <- Tags],
    Replacements#{Index => ext_syntax:generated("\n", erl_scan:location(Token)) ++
                           lists:append(Groups) ++ Replacement}.

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

group_tokens(none, Functions, Location) -> export_tokens(Functions, Location);
group_tokens({tag, Tag}, Functions, Location) ->
    Label = lists:flatten(io_lib:format("~tp", [Tag])),
    SafeLabel = lists:flatten(string:replace(string:replace(Label, "\n", "\\n", all),
                                             "\r", "\\r", all)),
    ext_syntax:generated(["%% ", SafeLabel, "\n"], Location) ++
        export_tokens(Functions, Location).

export_tokens(Functions, Location) ->
    Entries = [io_lib:format("~tp/~B", [Name, Arity]) || {Name, Arity} <- Functions],
    %% Both labeled and unlabeled groups end with a blank line.
    Text = lists:flatten(["-export([", lists:join(",", Entries), "]).\n\n"]),
    ext_syntax:generated(Text, Location).

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
format_error(invalid_tag) -> "_export accepts at most one atom tag: _export(api)";
format_error(expected_function) ->
    "_export must be followed by a function, with only comments or whitespace between";
format_error(conditional_export) ->
    "_export inside preprocessor conditionals is not supported; use a standard -export attribute";
format_error({invalid_function_head, {_, Module, Reason}}) ->
    lists:flatten(["invalid or unsupported function head after _export: ",
                   Module:format_error(Reason)]).
