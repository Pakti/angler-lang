%% Process boundary: source bytes on stdout, diagnostics on stderr.
-module(ext_cli).
-export([main/0, format_error/1]).

-define(VERSION, "0.3.0").

main() ->
    %% Treat standard input/output as bytes, not locale-dependent Unicode IO.
    ok = io:setopts(standard_io, [binary, {encoding, latin1}]),
    ok = io:setopts(standard_error, [{encoding, unicode}]),
    Status = dispatch(init:get_plain_arguments()),
    halt(Status).

dispatch(["--help"]) -> help();
dispatch(["-h"]) -> help();
dispatch(["--version"]) -> output("Angler " ?VERSION "\n");
dispatch([Command | Args]) when Command =:= "transpile"; Command =:= "snippet" ->
    case options(Args, utf8, [], false) of
        {ok, Encoding, Files} -> execute(Command, Encoding, Files);
        {error, Message} -> usage_error(Message)
    end;
dispatch(["build" | _]) -> usage_error("build mirroring is not implemented yet");
dispatch(_) -> usage_error("expected transpile FILE, snippet, --help, or --version").

options([], Encoding, Files, _) -> {ok, Encoding, lists:reverse(Files)};
options(["--" | Rest], Encoding, Files, false) ->
    options(Rest, Encoding, Files, true);
options(["--encoding", Value | Rest], _, Files, false)
  when Value =:= "utf8"; Value =:= "latin1" ->
    options(Rest, list_to_existing_atom(Value), Files, false);
options(["--encoding" | _], _, _, false) ->
    {error, "--encoding requires utf8 or latin1"};
options([[ $- | _ ] = Option | _], _, _, false) ->
    {error, "unknown option: " ++ Option};
options([File | Rest], Encoding, Files, EndOptions) ->
    options(Rest, Encoding, [File | Files], EndOptions).

execute("transpile", Encoding, [Path]) ->
    case file:read_file(Path) of
        {ok, Source} -> result(angler:transpile(Source, Encoding), Path);
        {error, Reason} -> diagnostic(Path, file:format_error(Reason))
    end;
execute("snippet", Encoding, []) ->
    case stdin() of
        {ok, Source} -> result(angler:snippet(Source, Encoding), "<stdin>");
        {error, Reason} -> diagnostic("<stdin>", file:format_error(Reason))
    end;
execute("transpile", _, _) -> usage_error("transpile requires exactly one input file");
execute("snippet", _, _) -> usage_error("snippet reads stdin and takes no file arguments").

%% The VM's terminal reader may decode stdin before IO options are changed.
%% With -noinput, open the descriptor directly and keep its original bytes.
stdin() ->
    case file:open("/dev/stdin", [read, raw, binary]) of
        {ok, Device} ->
            try read_stdin(Device, []) after file:close(Device) end;
        Error -> Error
    end.

read_stdin(Device, Chunks) ->
    case file:read(Device, 65536) of
        {ok, Chunk} -> read_stdin(Device, [Chunk | Chunks]);
        eof -> {ok, iolist_to_binary(lists:reverse(Chunks))};
        Error -> Error
    end.

result({ok, Source}, _) -> output(Source);
result({error, {Location, Module, Reason}}, Path) when is_atom(Module) ->
    diagnostic(Path, [location(Location), Module:format_error(Reason)]);
result({error, Reason}, Path) -> diagnostic(Path, format_error(Reason)).

location({Line, Column}) -> io_lib:format("~B:~B: ", [Line, Column]);
location(Line) -> io_lib:format("~B: ", [Line]).

format_error({invalid_encoding, Encoding}) ->
    io_lib:format("invalid or incomplete ~p input", [Encoding]).

output(Data) ->
    case file:write(standard_io, Data) of
        ok -> 0;
        {error, Reason} -> diagnostic("<stdout>", file:format_error(Reason))
    end.

diagnostic(Path, Message) ->
    io:format(standard_error, "~ts: ~ts~n", [Path, Message]),
    1.

usage_error(Message) ->
    io:format(standard_error, "angler: ~ts~nTry angler --help for usage.~n", [Message]),
    2.

help() -> output(
    "Usage: angler transpile [--encoding utf8|latin1] [--] FILE\n"
    "       angler snippet [--encoding utf8|latin1]\n"
    "       angler --help | --version\n\n"
    "transpile writes one source file to stdout; snippet reads expressions from stdin.\n"
    "UTF-8 is the default. Diagnostics go to stderr; failures produce no source output.\n"
    "Snippet annotations and record shorthand await the types and records milestones.\n"
    "Build mirroring and Eqwalizer are not implemented yet.\n").
