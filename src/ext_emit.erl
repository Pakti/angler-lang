%% Reconstruct source from token text, never from formatted token values.
-module(ext_emit).
-export([emit/1]).

-spec emit(ext_scan:document()) -> binary() | string().
emit(#{tokens := Tokens, kind := Kind, encoding := Encoding, prefix := Prefix}) ->
    Text = [erl_scan:text(Token) || Token <- Tokens],
    case Kind of
        list -> lists:append(Text);
        binary ->
            Body = unicode:characters_to_binary(Text, unicode, Encoding),
            <<Prefix/binary, Body/binary>>
    end.
