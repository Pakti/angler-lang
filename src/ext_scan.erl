%% Lossless lexical scanning. No parsing or preprocessing is performed here.
-module(ext_scan).
-export([scan/1, scan/2, tokens/1, significant/1]).
-export_type([document/0]).

-type document() :: #{tokens := [erl_scan:token()],
                        kind := binary | list,
                        encoding := utf8 | latin1,
                        prefix := binary()}.

%% Binaries default to UTF-8; lists contain Unicode code points.
-spec scan(binary() | string()) -> {ok, document()} | {error, term()}.
scan(Source) -> scan(Source, utf8).

-spec scan(binary() | string(), utf8 | latin1) ->
    {ok, document()} | {error, term()}.
scan(Source, Encoding) when is_binary(Source),
                            (Encoding =:= utf8 orelse Encoding =:= latin1) ->
    {Prefix, Body} = strip_bom(Source, Encoding),
    case unicode:characters_to_list(Body, Encoding) of
        Chars when is_list(Chars) -> scan_chars(Chars, binary, Encoding, Prefix);
        {error, _, _} -> {error, {invalid_encoding, Encoding}};
        {incomplete, _, _} -> {error, {invalid_encoding, Encoding}}
    end;
scan(Source, Encoding) when is_list(Source),
                            (Encoding =:= utf8 orelse Encoding =:= latin1) ->
    scan_chars(Source, list, Encoding, <<>>).

scan_chars(Chars, Kind, Encoding, Prefix) ->
    case erl_scan:string(Chars, {1, 1},
                         [text, return_comments, return_white_spaces]) of
        {ok, Tokens, _EndLocation} ->
            {ok, #{tokens => Tokens, kind => Kind,
                   encoding => Encoding, prefix => Prefix}};
        {error, ErrorInfo, _EndLocation} -> {error, ErrorInfo}
    end.

strip_bom(<<239, 187, 191, Rest/binary>>, utf8) ->
    {<<239, 187, 191>>, Rest};
strip_bom(Source, _) -> {<<>>, Source}.

-spec tokens(document()) -> [erl_scan:token()].
tokens(#{tokens := Tokens}) -> Tokens.

%% One-based positions refer to the complete stream, including trivia.
%% Keep the original annotations and text on significant tokens too.
-spec significant(document()) -> [{pos_integer(), erl_scan:token()}].
significant(Document) ->
    [{Index, Token} || {Index, Token} <-
        lists:zip(lists:seq(1, length(tokens(Document))), tokens(Document)),
        erl_scan:category(Token) =/= white_space,
        erl_scan:category(Token) =/= comment].
