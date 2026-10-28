%% Incremental tree synchronization. Per-file publication, no tree rollback.
-module(ext_build).
-include_lib("kernel/include/file.hrl").
-export([run/1, format_error/1]).

run(Options) ->
    Opts = maps:merge(
        #{
            input => "src_ex",
            output => "src",
            clean => false,
            delete => false,
            encoding => utf8
        },
        Options
    ),
    try
        Input = absolute(maps:get(input, Opts)),
        Output = absolute(maps:get(output, Opts)),
        no_symlink_components(Input),
        no_symlink_components(Output),
        case prefix(Input, Output) orelse prefix(Output, Input) of
            true -> fail(Output, overlapping_paths);
            false -> ok
        end,
        require_directory(Input),
        {Files, Dirs} = inventory(Input, "", input),
        Plan = plan(Files, Dirs),
        validate_output(Output, Plan, Dirs),
        make_directory(Output),
        lists:foreach(fun(D) -> make_directory(filename:join(Output, D)) end, Dirs),
        execute(
            Plan,
            Input,
            Output,
            Dirs,
            Opts#{expected => [D || {_, D, _} <- Plan]},
            #{written => 0, skipped => 0, deleted => 0},
            []
        )
    catch
        throw:{build_error, Path, Reason} -> {error, {Path, ?MODULE, Reason}, []}
    end.

%% Normalize dot segments before checking overlap; existing symlink components
%% are rejected, so these lexical paths cannot alias through directory links.
absolute(Path) ->
    filename:join(lists:reverse(normalize(filename:split(filename:absname(Path)), []))).
normalize([], Acc) -> Acc;
normalize(["." | Rest], Acc) -> normalize(Rest, Acc);
normalize([".." | Rest], ["/" = Root]) -> normalize(Rest, [Root]);
normalize([".." | Rest], [_ | Acc]) -> normalize(Rest, Acc);
normalize([Part | Rest], Acc) -> normalize(Rest, [Part | Acc]).
prefix(A, B) -> lists:prefix(filename:split(A), filename:split(B)).

no_symlink_components(Path) ->
    lists:foldl(
        fun(Part, Parent) ->
            Current =
                case Parent of
                    "" -> Part;
                    _ -> filename:join(Parent, Part)
                end,
            case info(Current) of
                #file_info{type = symlink} -> fail(Current, symlink_path);
                _ -> ok
            end,
            Current
        end,
        "",
        filename:split(Path)
    ),
    ok.

info(Path) ->
    case file:read_link_info(Path, [{time, posix}]) of
        {ok, Info} -> Info;
        {error, enoent} -> missing;
        {error, Reason} -> fail(Path, {io, Reason})
    end.
require_directory(Path) ->
    case info(Path) of
        #file_info{type = directory} -> ok;
        missing -> fail(Path, missing_input);
        _ -> fail(Path, expected_directory)
    end.

%% Symlinks and special files are never followed. Output symlinks are leaves
%% eligible for warning/unlinking; input links are unsupported rather than copied.
inventory(Root, Relative, Mode) ->
    Directory = join(Root, Relative),
    Names =
        case file:list_dir(Directory) of
            {ok, Entries} -> lists:sort(Entries);
            {error, Reason} -> fail(Directory, {io, Reason})
        end,
    lists:foldl(
        fun(Name, {Files, Dirs}) ->
            Rel = join(Relative, Name),
            Path = filename:join(Root, Rel),
            case info(Path) of
                #file_info{type = directory} ->
                    {Children, Subdirs} = inventory(Root, Rel, Mode),
                    {Files ++ Children, Dirs ++ [Rel | Subdirs]};
                #file_info{type = regular} ->
                    {Files ++ [Rel], Dirs};
                #file_info{type = symlink} when Mode =:= output -> {Files ++ [Rel], Dirs};
                #file_info{type = symlink} ->
                    fail(Path, input_symlink);
                _ ->
                    fail(Path, unsupported_file)
            end
        end,
        {[], []},
        Names
    ).
join("", Name) -> Name;
join(Parent, "") -> Parent;
join(Parent, Name) -> filename:join(Parent, Name).

plan(Files, Dirs) ->
    {Plan, _} = lists:foldl(
        fun(Source, {Acc, Seen}) ->
            Kind =
                case filename:extension(Source) of
                    ".erlx" -> transpile;
                    _ -> copy
                end,
            Dest =
                case Kind of
                    transpile -> filename:rootname(Source, ".erlx") ++ ".erl";
                    copy -> Source
                end,
            case maps:find(Dest, Seen) of
                {ok, Other} -> fail(Source, {collision, Dest, Other});
                error -> ok
            end,
            case lists:member(Dest, Dirs) of
                true -> fail(Source, {directory_collision, Dest});
                false -> ok
            end,
            {[{Source, Dest, Kind} | Acc], Seen#{Dest => Source}}
        end,
        {[], #{}},
        Files
    ),
    lists:reverse(Plan).

validate_output(Output, Plan, Dirs) ->
    lists:foreach(
        fun(Rel) ->
            Path = join(Output, Rel),
            case info(Path) of
                missing -> ok;
                #file_info{type = directory} -> ok;
                _ -> fail(Path, expected_directory)
            end
        end,
        ["" | Dirs]
    ),
    lists:foreach(
        fun({_, Dest, _}) ->
            Path = filename:join(Output, Dest),
            case info(Path) of
                missing -> ok;
                #file_info{type = regular} -> ok;
                #file_info{type = symlink} -> fail(Path, symlink_path);
                _ -> fail(Path, expected_regular_file)
            end
        end,
        Plan
    ).

make_directory(Path) ->
    case filelib:ensure_path(Path) of
        ok -> ok;
        {error, Reason} -> fail(Path, {io, Reason})
    end.

execute([], _, Output, Dirs, Opts, Stats, Warnings) ->
    try
        finish(Output, Dirs, Opts, Stats, Warnings)
    catch
        throw:{build_error, Path, Reason} -> {error, {Path, ?MODULE, Reason}, Warnings}
    end;
execute([{Source, Dest, Kind} | Rest], Input, Output, Dirs, Opts, Stats, Warnings) ->
    SourcePath = filename:join(Input, Source),
    DestPath = filename:join(Output, Dest),
    try
        %% Recheck file types before using either path. No stale symlink targets.
        no_symlink_components(SourcePath),
        no_symlink_components(DestPath),
        SourceInfo =
            case info(SourcePath) of
                #file_info{type = regular} = SI -> SI;
                missing -> fail(SourcePath, {io, enoent});
                _ -> fail(SourcePath, unsupported_file)
            end,
        SourceTime = SourceInfo#file_info.mtime,
        Stale =
            case info(DestPath) of
                missing ->
                    true;
                #file_info{type = regular, mtime = DestTime} = DI ->
                    case
                        DI#file_info.inode > 0 andalso
                            DI#file_info.inode =:= SourceInfo#file_info.inode andalso
                            DI#file_info.major_device =:= SourceInfo#file_info.major_device
                    of
                        true -> fail(DestPath, hardlink_alias);
                        false -> SourceTime > DestTime
                    end;
                _ ->
                    fail(DestPath, expected_regular_file)
            end,
        %% Validate extended source even when timestamps permit skipping the
        %% write, so repeat builds retain diagnostics and warnings-as-errors.
        {Data, FileWarnings} = contents(SourcePath, Kind, maps:get(encoding, Opts)),
        {NextStats, NextWarnings} =
            case Stale orelse maps:get(clean, Opts) of
                true ->
                    publish(DestPath, Data, SourceInfo#file_info.mode, SourceTime),
                    {increment(written, Stats), Warnings ++ FileWarnings};
                false ->
                    {increment(skipped, Stats), Warnings ++ FileWarnings}
            end,
        execute(Rest, Input, Output, Dirs, Opts, NextStats, NextWarnings)
    catch
        throw:{build_error, Path, Reason} ->
            {error, {Path, ?MODULE, Reason}, Warnings};
        throw:{transpile_error, Path, Reason} ->
            {error, {Path, ?MODULE, {transpile, Reason}}, Warnings}
    end.

contents(Path, copy, _) ->
    {{copy, Path}, []};
contents(Path, transpile, Encoding) ->
    case angler:transpile_with_warnings(read(Path), Encoding) of
        {ok, Bytes, Warnings} -> {Bytes, [{Path, W} || W <- Warnings]};
        {error, Reason} -> throw({transpile_error, Path, Reason})
    end.
read(Path) ->
    case file:read_file(Path) of
        {ok, Bytes} -> Bytes;
        {error, Reason} -> fail(Path, {io, Reason})
    end.

%% Rename a private sibling instead of writing through existing hardlinks or
%% exposing partially written files. This is not a transaction across the tree.
publish(Path, Data, Mode, SourceTime) ->
    Temp = filename:join(
        filename:dirname(Path), ".angler-" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    case file:open(Temp, [write, raw, binary, exclusive]) of
        {ok, Device} ->
            try
                write_data(Temp, Device, Data),
                checked(Temp, file:close(Device)),
                checked(Temp, file:change_mode(Temp, Mode band 8#777)),
                checked(
                    Temp,
                    file:write_file_info(
                        Temp, #file_info{mtime = max(SourceTime, erlang:system_time(second))}, [
                            {time, posix}
                        ]
                    )
                ),
                checked(Path, file:rename(Temp, Path))
            after
                file:close(Device),
                file:delete(Temp)
            end;
        {error, eexist} ->
            publish(Path, Data, Mode, SourceTime);
        {error, Reason} ->
            fail(Temp, {io, Reason})
    end.

write_data(Temp, Device, {copy, Source}) ->
    case file:copy(Source, Device) of
        {ok, _Bytes} -> ok;
        {error, Reason} -> fail(Temp, {io, Reason})
    end;
write_data(Temp, Device, Bytes) ->
    checked(Temp, file:write(Device, Bytes)).

finish(Output, Dirs, Opts, Stats, Warnings) ->
    {Files, OutputDirs} = inventory(Output, "", output),
    Expected = maps:get(expected, Opts),
    Extras = [F || F <- Files, not lists:member(F, Expected)],
    case maps:get(delete, Opts) of
        false ->
            Empty = [
                D
             || D <- OutputDirs,
                not lists:member(D, Dirs),
                not lists:any(fun(F) -> prefix(D, F) end, Files)
            ],
            ExtraWarnings =
                [{filename:join(Output, F), {none, ?MODULE, extra_file}} || F <- Extras] ++
                    [{filename:join(Output, D), {none, ?MODULE, extra_directory}} || D <- Empty],
            {ok, Stats, Warnings ++ ExtraWarnings};
        true ->
            lists:foreach(
                fun(F) ->
                    checked(filename:join(Output, F), file:delete(filename:join(Output, F)))
                end,
                Extras
            ),
            Prune = lists:sort(
                fun(A, B) -> length(filename:split(A)) > length(filename:split(B)) end, OutputDirs
            ),
            lists:foreach(
                fun(D) ->
                    Path = filename:join(Output, D),
                    case lists:member(D, Dirs) of
                        true ->
                            ok;
                        false ->
                            case file:list_dir(Path) of
                                {ok, []} -> checked(Path, file:del_dir(Path));
                                {ok, _} -> ok;
                                {error, Reason} -> fail(Path, {io, Reason})
                            end
                    end
                end,
                Prune
            ),
            {ok, Stats#{deleted := length(Extras)}, Warnings}
    end.
increment(Key, Stats) -> Stats#{Key := maps:get(Key, Stats) + 1}.
checked(_, ok) -> ok;
checked(Path, {error, Reason}) -> fail(Path, {io, Reason}).
fail(Path, Reason) -> throw({build_error, Path, Reason}).

format_error({io, Reason}) ->
    file:format_error(Reason);
format_error({collision, Dest, Other}) ->
    io_lib:format("destination ~ts also maps from ~ts", [Dest, Other]);
format_error({directory_collision, Dest}) ->
    io_lib:format("destination ~ts collides with an input directory", [Dest]);
format_error({transpile, {Location, Module, Reason}}) ->
    io_lib:format("~p: ~ts", [Location, Module:format_error(Reason)]);
format_error({transpile, {invalid_encoding, Encoding}}) ->
    io_lib:format("invalid or incomplete ~p input", [Encoding]);
format_error({transpile, Reason}) ->
    io_lib:format("transpilation failed: ~tp", [Reason]);
format_error(overlapping_paths) ->
    "input and output directories must not overlap";
format_error(hardlink_alias) ->
    "mapped output is hard-linked to its input; remove that output link explicitly";
format_error(symlink_path) ->
    "symlinks are not allowed in input/output roots or mapped output paths";
format_error(input_symlink) ->
    "input symlinks are not supported";
format_error(missing_input) ->
    "input directory does not exist";
format_error(expected_directory) ->
    "expected a directory (remove any blocking output entry explicitly)";
format_error(expected_regular_file) ->
    "expected a regular output file";
format_error(unsupported_file) ->
    "unsupported file type";
format_error(extra_file) ->
    "extra output file left untouched; use --delete to remove extras";
format_error(extra_directory) ->
    "extra empty output directory left untouched; use --delete to remove extras".
