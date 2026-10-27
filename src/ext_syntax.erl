%% Shared indexed-token traversal; delimiters and expression blocks nest.
-module(ext_syntax).
-export([split/2, clauses/1, take/2, text/1, generated/2, apply/2, remove/2, error/2]).

%% Guard alternatives also use semicolons; only split after a clause arrow.
clauses([]) -> [];
clauses(Tokens) ->
    case take(Tokens, '->') of
        {Head, [Arrow | Tail]} ->
            {Body, After} = take(Tail, ';'),
            Clause = Head ++ [Arrow | Body],
            case After of [] -> [Clause]; [_ | Rest] -> [Clause | clauses(Rest)] end;
        _ -> [Tokens]
    end.

split(Tokens, Separator) -> split(Tokens, Separator, [], [], []).
split([], _, _, Current, Parts) -> lists:reverse([lists:reverse(Current) | Parts]);
split([{_, T} = Entry | Rest], Separator, Stack, Current, Parts) ->
    case {erl_scan:category(T), Stack} of
        {Separator, []} -> split(Rest, Separator, [], [], [lists:reverse(Current) | Parts]);
        _ -> split(Rest, Separator, stack(T, Rest, Stack), [Entry | Current], Parts)
    end.

take(Tokens, Separator) -> take(Tokens, Separator, [], []).
take([], _, _, Acc) -> {lists:reverse(Acc), []};
take([{_, T} = Entry | Rest], Separator, Stack, Acc) ->
    case {erl_scan:category(T), Stack} of
        {Separator, []} -> {lists:reverse(Acc), [Entry | Rest]};
        _ -> take(Rest, Separator, stack(T, Rest, Stack), [Entry | Acc])
    end.

stack(T, Rest, Stack) ->
    case erl_scan:category(T) of
        '(' -> [')' | Stack]; '[' -> [']' | Stack];
        '{' -> ['}' | Stack]; '<<' -> ['>>' | Stack];
        'case' -> ['end' | Stack]; 'if' -> ['end' | Stack];
        'receive' -> ['end' | Stack]; 'try' -> ['end' | Stack];
        'begin' -> ['end' | Stack]; 'maybe' -> ['end' | Stack];
        'fun' -> case Rest of
            [{_, {'(', _}} | Tail] ->
                case take(Tail, ')') of
                    {_, [{_, {')', _}}, {_, {Next, _}} | _]} when Next =:= '->'; Next =:= 'when' -> ['end' | Stack];
                    _ -> Stack
                end;
            [{_, {var, _, _}}, {_, {'(', _}} | _] -> ['end' | Stack];
            _ -> Stack
        end;
        Close -> case Stack of [Close | Tail] -> Tail; _ -> Stack end
    end.

text(Entries) -> lists:flatten(lists:join(" ", [erl_scan:text(T) || {_, T} <- Entries])).
generated(Text, Location) ->
    {ok, Tokens, _} = erl_scan:string(lists:flatten(Text), Location,
                                    [text, return_comments, return_white_spaces]),
    Tokens.
apply(Document, Edits) ->
    Tokens = ext_scan:tokens(Document),
    Document#{tokens := lists:append([maps:get(I, Edits, [T]) ||
        {I, T} <- lists:zip(lists:seq(1, length(Tokens)), Tokens)])}.
remove(Entries, Edits) -> lists:foldl(fun({I, _}, Acc) -> Acc#{I => []} end, Edits, Entries).
error(Entry, Reason) ->
    {_, Token} = Entry,
    throw({syntax_error, erl_scan:location(Token), Reason}).
