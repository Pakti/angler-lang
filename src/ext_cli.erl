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
dispatch([Command | Args]) when Command =:= "transpile"; Command =:= "snippet"; Command =:= "build" ->
    Defaults = #{encoding => utf8, input => "src_ex", output => "src",
                 clean => false, delete => false, warnings_as_errors => false},
    case options(Args, Command, Defaults, [], false) of
        {ok, Opts, Files} -> execute(Command, Opts, Files);
        {error, Message} -> usage_error(Message)
    end;
dispatch(_) -> usage_error("expected build, transpile FILE, snippet, --help, or --version").

options([], _, Opts, Files, _) -> {ok, Opts, lists:reverse(Files)};
options(["--" | Rest], Command, Opts, Files, false) ->
    options(Rest, Command, Opts, Files, true);
options(["--encoding", Value | Rest], Command, Opts, Files, false)
  when Value =:= "utf8"; Value =:= "latin1" ->
    options(Rest, Command, Opts#{encoding := list_to_existing_atom(Value)}, Files, false);
options(["--encoding" | _], _, _, _, false) -> {error, "--encoding requires utf8 or latin1"};
options(["--warnings-as-errors" | Rest], Command, Opts, Files, false) ->
    options(Rest, Command, Opts#{warnings_as_errors := true}, Files, false);
options([Flag | Rest], "build", Opts, Files, false)
  when Flag =:= "--clean"; Flag =:= "--delete"; Flag =:= "-d" ->
    Key = case Flag of "--clean" -> clean; _ -> delete end,
    options(Rest, "build", Opts#{Key := true}, Files, false);
options([Flag, Path | Rest], "build", Opts, Files, false)
  when Flag =:= "--input"; Flag =:= "--output" ->
    Key = case Flag of "--input" -> input; _ -> output end,
    options(Rest, "build", Opts#{Key := Path}, Files, false);
options([Flag], "build", _, _, false) when Flag =:= "--input"; Flag =:= "--output" ->
    {error, Flag ++ " requires a directory"};
options([[$- | _] = Option | _], _, _, _, false) -> {error, "unknown option: " ++ Option};
options([File | Rest], Command, Opts, Files, EndOptions) ->
    options(Rest, Command, Opts, [File | Files], EndOptions).

execute("build", Opts, []) ->
    case angler:build(Opts) of
        {ok, _Stats, Warnings} -> warnings(Warnings, Opts);
        {error, {Path, Module, Reason}, Warnings} ->
            warnings(Warnings, Opts),
            diagnostic(Path, Module:format_error(Reason))
    end;
execute("transpile", Opts, [Path]) ->
    case file:read_file(Path) of
        {ok, Source} -> result(angler:transpile_with_warnings(Source, maps:get(encoding, Opts)), Path, Opts);
        {error, Reason} -> diagnostic(Path, file:format_error(Reason))
    end;
execute("snippet", Opts, []) ->
    case stdin() of
        {ok, Source} -> result(angler:snippet(Source, maps:get(encoding, Opts)), "<stdin>", Opts);
        {error, Reason} -> diagnostic("<stdin>", file:format_error(Reason))
    end;
execute("build", _, _) -> usage_error("build takes --input and --output options, not positional paths");
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

result({ok, Source, Warnings}, Path, Opts) ->
    Status = warnings([{Path, W} || W <- Warnings], Opts),
    %% Warning promotion is a status policy: successfully transformed source
    %% is still emitted, just as build writes remain when warnings are errors.
    case output(Source) of 0 -> Status; Error -> Error end;
result({ok, Source}, _, _) -> output(Source);
result({error, {Location, Module, Reason}}, Path, _) when is_atom(Module) ->
    diagnostic(Path, [location(Location), Module:format_error(Reason)]);
result({error, Reason}, Path, _) -> diagnostic(Path, format_error(Reason)).

warnings(Warnings, Opts) ->
    lists:foreach(fun({Path, {Location, Module, Reason}}) ->
        io:format(standard_error, "~ts: ~tswarning: ~ts~n",
                  [Path, location(Location), Module:format_error(Reason)])
    end, Warnings),
    case Warnings =/= [] andalso maps:get(warnings_as_errors, Opts) of
        true -> 1;
        false -> 0
    end.

location(none) -> "";
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
    "Usage: angler build [--input DIR] [--output DIR] [--clean] [-d|--delete]\n"
    "       angler transpile [--encoding utf8|latin1] [--] FILE\n"
    "       angler snippet [--encoding utf8|latin1]\n"
    "       angler --help | --version\n\n"
    "build maps src_ex/ to src/ by default. Extras are warned about and preserved.\n"
    "--clean regenerates mapped files; only -d/--delete removes extras.\n"
    "--warnings-as-errors is accepted by build, transpile, and snippet.\n"
    "Warnings still display and successful output remains, but exit status becomes 1.\n"
    "build also accepts --encoding utf8|latin1 for .erlx files (UTF-8 by default).\n"
    "transpile writes one file to stdout; snippet reads expressions from stdin.\n"
    "Diagnostics go to stderr. Eqwalizer and export tags are not implemented yet.\n").
