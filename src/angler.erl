%% Public transformation entry point. Later milestones extend this pipeline.
-module(angler).
-export([transpile/1, transpile/2, snippet/1, snippet/2, transpile_with_warnings/2, format_error/1, build/0, build/1]).

%% Options: input/output paths, clean/delete booleans, and source encoding.
build() -> build(#{}).
build(Options) -> ext_build:run(Options).

-spec transpile(binary() | string()) ->
    {ok, binary() | string()} | {error, term()}.
transpile(Source) -> transpile(Source, utf8).

-spec transpile(binary() | string(), utf8 | latin1) ->
    {ok, binary() | string()} | {error, term()}.
transpile(Source, Encoding) ->
    case transpile_with_warnings(Source, Encoding) of
        {ok, Output, _Warnings} -> {ok, Output};
        Error -> Error
    end.

%% Callers that need diagnostics can retain warnings through this API.
transpile_with_warnings(Source, Encoding) ->
    case ext_scan:scan(Source, Encoding) of
        {ok, Document} ->
            case rewrite_module(Document) of
                {ok, Typed, Warnings} ->
                    case ext_exports:rewrite(Typed) of
                        {ok, Rewritten} -> {ok, ext_emit:emit(Rewritten), Warnings};
                        Error -> Error
                    end;
                Error -> Error
            end;
        Error -> Error
    end.

rewrite_module(Document) ->
    case ext_records:rewrite(Document, module) of
        {ok, Records} -> ext_types:rewrite(Records);
        Error -> Error
    end.

%% Snippets are expression sequences, never module forms. Do not run the
%% module export pass here. Later expression rewrites belong before parsing.
-spec snippet(binary() | string()) ->
    {ok, binary() | string()} | {error, term()}.
snippet(Source) -> snippet(Source, utf8).

-spec snippet(binary() | string(), utf8 | latin1) ->
    {ok, binary() | string()} | {error, term()}.
snippet(Source, Encoding) ->
    case ext_scan:scan(Source, Encoding) of
        {ok, Document} ->
            case ext_records:rewrite(Document, snippet) of
                {ok, Records} ->
                    Tokens = [T || {_, T} <- ext_scan:significant(Records)],
                    case snippet_tokens(Tokens) of
                        ok -> {ok, ext_emit:emit(Records)};
                        Error -> Error
                    end;
                Error -> Error
            end;
        Error -> Error
    end.

snippet_tokens([]) -> ok;
snippet_tokens([{'-', _}, {atom, Anno, Name} | _])
  when Name =:= module; Name =:= export; Name =:= import;
       Name =:= record; Name =:= spec; Name =:= type;
       Name =:= opaque; Name =:= include; Name =:= include_lib;
       Name =:= define; Name =:= compile ->
    {error, {erl_anno:location(Anno), ?MODULE, module_form_in_snippet}};
snippet_tokens(Tokens) ->
    case erl_parse:parse_exprs(Tokens) of
        {ok, _Expressions} -> ok;
        {error, ErrorInfo} -> {error, ErrorInfo}
    end.

format_error(module_form_in_snippet) ->
    "snippet expects expressions, not module attributes".
