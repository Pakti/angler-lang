%% Public transformation entry point. Later milestones extend this pipeline.
-module(angler).
-export([transpile/1, transpile/2]).

-spec transpile(binary() | string()) ->
    {ok, binary() | string()} | {error, term()}.
transpile(Source) -> transpile(Source, utf8).

-spec transpile(binary() | string(), utf8 | latin1) ->
    {ok, binary() | string()} | {error, term()}.
transpile(Source, Encoding) ->
    case ext_scan:scan(Source, Encoding) of
        {ok, Document} ->
            case ext_exports:rewrite(Document) of
                {ok, Rewritten} -> {ok, ext_emit:emit(Rewritten)};
                Error -> Error
            end;
        Error -> Error
    end.
