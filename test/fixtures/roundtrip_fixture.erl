-module(roundtrip_fixture).
-export([run/0]).
-include("roundtrip_fixture.hrl").
%% Whitespace and source locations must survive the scanner/emitter.
run() ->
    P0 = #person{}, P = ?NEXT(P0),
    {?LINE, P#person.age}.
