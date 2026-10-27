%% Top-level lexical forms, retaining indices into the lossless token stream.
-module(ext_forms).
-export([forms/1, function/1]).
-export_type([form/0]).

-type form() :: [{pos_integer(), erl_scan:token()}].

-spec forms(ext_scan:document()) -> [form()].
forms(Document) -> split(ext_scan:significant(Document), [], []).

split([], [], Forms) -> lists:reverse(Forms);
split([], Current, Forms) -> lists:reverse([lists:reverse(Current) | Forms]);
split([{_, Token} = Entry | Rest], Current, Forms) ->
    case erl_scan:category(Token) of
        dot -> split(Rest, [], [lists:reverse([Entry | Current]) | Forms]);
        _ -> split(Rest, [Entry | Current], Forms)
    end.

%% Parse only the first head, with a dummy body. Erlang's parser counts
%% arguments (including nested patterns) and validates guards. Bodies can
%% contain macros, includes are left to the eventual standard compiler.
-spec function(form()) -> {ok, {atom(), arity()}} | {error, term()}.
function([{_, {atom, _, _}} | _] = Form) ->
    case lists:splitwith(fun({_, T}) -> erl_scan:category(T) =/= '->' end, Form) of
        {Head, [{_, Arrow} | _]} ->
            Anno = element(2, Arrow),
            Tokens = [T || {_, T} <- Head] ++
                     [Arrow, {atom, Anno, ok}, {dot, Anno}],
            case erl_parse:parse_form(Tokens) of
                {ok, {function, _, Name, Arity, _}} -> {ok, {Name, Arity}};
                {error, Reason} -> {error, {invalid_function_head, Reason}}
            end;
        _ -> {error, expected_function}
    end;
function(_) -> {error, expected_function}.
