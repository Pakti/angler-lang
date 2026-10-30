# Angler

Angler adds a little syntactic sugar to Erlang to reduce repetition while keeping
code familiar to Erlang programmers. It preprocesses `.erlx` files into ordinary
`.erl` files, with no new runtime or type checker. The generated files remain
usable without Angler.

**Alpha software.** Developed and tested on Linux with Erlang/OTP 27; use on
OTP 29, including native-record syntax, has also been verified by the author.
Syntax support depends on the OTP version running Angler.

Angler currently provides:

- **An `_export` qualifier for top-level functions**, optionally tagged to group
  generated export attributes -- this makes readily apparent which functions are
  exported and which not, and how exported functions are related;
- **Inline function types:** argument and return annotations generate `-spec`
  declarations, including overloaded specs.
- **Concise tuple-record operations:** `P.age` and `P{age = 42}`, using an
  annotation or a simple local binding to establish the record name.
- **CLI and project builds:** transpile files, pipe expression snippets, or
  incrementally mirror an extended-source tree into ordinary Erlang.
- **Emacs support:** an `erlang-mode`-derived major mode with highlighting,
  indentation, navigation, and commands to preprocess code for an Erlang shell.

## A small example

```erlang
-module(example).
-record(person, {name, age}).

_export(people)
birthday(P :: #person{}) :: #person{} ->
    P{age = P.age + 1}.
```

Generated Erlang, formatted with `erlfmt`:

```erlang
-module(example).

%% people
-export([birthday/1]).

-record(person, {name, age}).

-spec birthday(#person{}) -> #person{}.
birthday(P) ->
    P#person{age = P#person.age + 1}.
```

Annotations are optional. Functions without types get no generated spec.
Comments and untouched source text are retained; Angler leaves standard layout
to an external formatter such as `erlfmt`.

See [example/example.erlx](example/example.erlx) for grouped exports, local
annotations, record-name deduction, and overloaded specs. Run it with `make demo`.

## Quick start

Install Erlang/OTP with its compiler, then build from the checkout:

```sh
make
make demo
```

Transpile and compile your own file:

```sh
bin/angler transpile path/to/example.erlx > example.erl
# Optional; requires Rebar3 and downloads the erlfmt plugin on first use:
rebar3 fmt -w example.erl
erlc example.erl
```

Write output to a different path from the input. Add the checkout's `bin/`
directory to `PATH` to use `angler` from other directories. The launcher finds
its compiled modules relative to itself; input paths are relative to your
working directory. Run `make` or `rebar3 compile` again after changing Angler.

The CLI targets Unix-like systems. Angler has no application dependencies or
required services. Rebar3 is optional for building, and required for the
formatting commands shown here; its configuration pins erlfmt 1.8.0.

## Command-line use

| Command | Purpose |
| --- | --- |
| `angler transpile FILE` | Transpile a module file to stdout. |
| `angler snippet` | Read an expression sequence from stdin and emit shell-ready Erlang. |
| `angler build` | Mirror `src_ex/` into `src/`, transpiling `.erlx` files. |
| `angler --help` / `angler --version` | Show usage / version. |

```sh
angler transpile example.erlx > example.erl
printf 'P :: #person{} = get_person(), P.name.\n' | angler snippet
angler build --input source --output generated
```

Snippet mode accepts expressions terminated by a period, not module attributes
or function definitions. It removes local annotations and rewrites record
shorthand; it never evaluates code or generates exports/specs. The Erlang shell
must already have any required variables and record definitions.

All three source commands accept `--encoding utf8|latin1` (default: UTF-8) and
`--warnings-as-errors`. Use `--` before filenames starting with `-`.
Diagnostics go to stderr; `transpile` and `snippet` write only source to stdout.

### Project builds

In a consuming project, keep authoritative files in `src_ex/` and generated
files in `src/`:

```text
src_ex/server.erlx       -> src/server.erl
src_ex/protocol.erl      -> src/protocol.erl
src_ex/include/types.hrl -> src/include/types.hrl
src_ex/settings.json     -> src/settings.json
```

Every non-`.erlx` file is copied byte-for-byte. Builds preserve relative paths
and write missing or older outputs. Extras in the output tree produce warnings
and are preserved by default.

| Option | Effect |
| --- | --- |
| `--input DIR`, `--output DIR` | Override `src_ex/` and `src/`. |
| `--clean` | Regenerate/re-copy all mapped files, regardless of timestamps. |
| `-d`, `--delete` | Delete extras after generation/copying succeeds. |
| `--clean --delete` | Force regeneration and remove extras. |
| `--warnings-as-errors` | Display warnings and return a failure status. |

Use `--clean` after changing the transpiler version or options. It does not
imply deletion. Warning promotion changes the exit status, not the output:
successful writes and explicitly requested deletions remain.

Do not edit generated files as your only copy. In this repository, `src/`
contains Angler's handwritten implementation; use another output directory
when trying build mirroring here. See [build details](#build-details) for
collision checks and failure behavior.

## Emacs

Ensure the Erlang distribution's `erlang.el` is on Emacs's `load-path`, then
load the mode and point it at the built CLI:

```elisp
;; Only needed if erlang.el is not already on load-path:
(add-to-list 'load-path "/path/to/otp/lib/tools-VERSION/emacs")
(load-file "/path/to/angler-lang/emacs/angler.el")
(setq angler-program "/path/to/angler-lang/bin/angler")
```

New `.erlx` buffers select `angler-mode` automatically; use `M-x angler-mode`
for an already open buffer. The mode inherits Erlang settings and hooks, with
Angler-aware highlighting, indentation, function/clause navigation, and Imenu.
Ordinary `.erl` buffers are unaffected.

| Command | Binding |
| --- | --- |
| Copy transpiled expression region | `C-c C-r` (`angler-copy-snippet`) |
| Send transpiled expression region to an Erlang shell | `C-c C-e` (`angler-send-snippet`) |
| Transpile the entire buffer into a separate Erlang buffer | `C-c C-t` (`angler-transpile-buffer`) |
| Build the project's output tree | `C-c C-k` (`angler-build`) |

Start a shell with `M-x erlang-shell` before sending expressions. Copy/send
accept expressions, not function definitions; use buffer transpilation for a
whole module. Buffer and region commands include unsaved edits without changing
the source. Project builds read files on disk, so save edits first.

Diagnostics appear in `*Angler diagnostics*`; file-backed buffers support
`next-error` navigation. Builds use `angler-compilation-mode`. Emacs must be
able to find `erl` through `PATH`. See [editor details](#editor-details) for
settings and shell selection.

## Known limitations

- **No general type inference or type checking.** Only limited local record-name
  deduction is performed. Use Erlang's compiler and a separate type checker.
  Eqwalizer-specific output is not implemented yet.
- **Macros contain ordinary Erlang only.** Angler does not expand macros or
  includes. Macro-generated heads/types have additional restrictions described
  below; `_export` is not supported inside preprocessor conditionals.
- **Record tracking is local and limited.** There is no branch-flow or full
  lexical-scope analysis; avoid shadowing annotated or deduced variable names.
  Annotated argument patterns must be simple variables.
- **No source mapping.** `?FILE` and `?LINE` are left to Erlang's preprocessor
  and can refer to the generated file/layout. Diagnostics and stack traces can
  likewise refer to generated code. Avoiding erlfmt does not guarantee original
  source positions; formatting can change line numbers further.
- **OTP compatibility follows the runtime.** Angler uses that OTP's scanner and
  parser. Passing newer syntax through module bodies does not establish support
  for it in function heads, annotations, or snippet parsing. Validate generated
  code with the OTP version you target.
- **Native and tuple records are distinct.** Angler's abbreviated operations
  target tuple-based records. OTP 29's native-record operations such as
  `P#_.age` and `P#_{age = 42}` are standard Erlang syntax, not Angler shorthand.

Supported ordinary Erlang without extensions is preserved byte-for-byte.
Transformed code has no line-number or standard-formatting guarantee. Applying
Angler again to generated ordinary Erlang leaves it unchanged.

## Syntax reference

### Exports

`_export` marks the immediately following function, including all clauses.
Only comments and whitespace may intervene; attributes (including `-spec`),
repeated directives, and multiple tags are errors.

```erlang
_export          % Unlabeled group.
start() -> ok.

_export(api)     % A single atom tag; quoted atoms are allowed too.
stop() -> ok.
```

Groups follow first-seen order, functions within a group follow source order,
and tagged groups receive a comment label. Generated groups are separated by
blank lines and inserted after `-module`, before other attributes/includes.
Tags only group output; they add no runtime metadata or behavior validation.

Existing literal, unconditional `-export` entries are preserved and deduplicated
against generated ones. Exports hidden in includes, macros, or conditionals
cannot be deduplicated this way. There is no export-by-name convention.
Macro-generated names, arguments, or guards on marked functions are unsupported;
use standard export attributes there and inside `-ifdef`/`-ifndef`/`-if` branches.

### Function types

Argument annotations go after simple variables; return annotations go before
an optional guard. Types use Erlang's type syntax, including unions, remote
types, records, and function types.

```erlang
encode(N :: integer()) :: binary() when is_integer(N) ->
    integer_to_binary(N);
encode(B :: binary()) :: binary() when is_binary(B) ->
    B.
```

This generates one overloaded spec:

```erlang
-spec encode(integer()) -> binary(); (binary()) -> binary().
```

Missing types contribute `any()`. If all types are `any()` (or absent), no spec
is generated. Partially annotated overloaded clauses retain their `any()`
fallbacks and produce a warning about broad or overlapping alternatives.
Unannotated argument patterns remain valid.

An explicit `-spec` plus **any inline function annotation** for the same
name/arity is an error, even for identical types or `any()`. Local annotations
are independent and remain usable with explicit specs. Macro-expanded argument
patterns cannot establish generated arity; use an explicit spec. Macro types
and constraints requiring explicit specifications are not implemented.

#### Planned constrained inline types

Constrained inline types are a planned extension, not currently supported.
Parentheses would separate a type's constraint list from function arguments
and runtime guards, for example:

```erlang
make(Tag :: (T when T :: atom()), Value :: V)
    :: strong(T, V) when is_atom(Tag) ->
    {Tag, Value}.
```

The intended output is:

```erlang
-spec make(T, V) -> strong(T, V) when T :: atom().
make(Tag, Value) when is_atom(Tag) ->
    {Tag, Value}.
```

Angler should preserve repeated constraints on the same type variable as
written, without simplifying them or trying to detect contradictions. More
generally, it should avoid extra semantic validation of malformed source and
leave type errors and contradictions to the Erlang compiler and/or Eqwalizer.
A quick check of the assembled spec with Erlang's parser is acceptable for
reporting syntax errors early; this does not imply type checking by Angler.

### Record shorthand and local annotations

`P.field` and `P{field = Value}` require a known tuple-record name. A direct
record annotation on an argument or local variable establishes that name:

```erlang
city(P :: #person{}) :: string() ->
    A :: #address{} = P.address,
    A.city.
```

The local annotation is erased; the body becomes equivalent to
`A = P#person.address, A#address.city`. Local hints do not emit type checks or
function specs. Other Erlang types can be used as hints, but only direct record
types enable record shorthand.

Simple top-level bindings also establish record names without annotations:

```erlang
P = #person{age = 41},          % Direct construction.
Older = P#person{age = 42},     % Ordinary record update.
Next = Older{age = 43},         % Shorthand update of a known record.
Alias = Next,                  % Alias of a known record variable.
Alias.age.
```

Deduction applies only to complete right-hand sides of simple `Variable = RHS`
bindings. It does not follow calls, field values, branches, macros, parenthesized
expressions, or nested patterns/bindings. `_` establishes no binding. The mapping
becomes available after the binding and resets at each top-level function clause
or snippet. Argument annotations seed each clause's environment; local hints
apply from their position onward, including within nested expressions.

Local annotations require `Variable :: Type = Expression` at an expression
boundary. Annotations within tuple/list patterns or anonymous-function heads
are unsupported. Repeating the same type is allowed; conflicting annotations
or deduced record names produce errors. A compatible record annotation retains
its field constraints. Actual field definitions/types are checked by Erlang's
compiler or shell, not by Angler.

Chained shorthand such as `P.address.city` is rejected; use an intermediate
annotated variable as above. The field atom must immediately follow the dot:
whitespace after a dot denotes an Erlang form terminator.

## Reference and development

### Library API

Build with Make or Rebar3, then start `erl -pa _build/default/lib/angler/ebin`:

```erlang
{ok, Erlang} = angler:transpile(Source),
{ok, Erlang, Warnings} = angler:transpile_with_warnings(Source, utf8),
{ok, Expressions} = angler:snippet(Snippet),
{ok, Stats, BuildWarnings} = angler:build(#{input => "src_ex", output => "src"}).
```

`transpile/2` and `snippet/2` accept `utf8` or `latin1`; one-argument forms
use UTF-8. APIs preserve binary versus Unicode character-list representation.
`transpile/1,2` discard warnings; use `transpile_with_warnings/2` to retain them.
Transformation errors return `{error, Reason}`, commonly
`{Location, Module, Description}`; use the indicated module's `format_error/1`.

`build/0` uses defaults. `build/1` accepts `input`, `output`, `clean`, `delete`,
and `encoding`; it returns `{ok, Stats, Warnings}` or
`{error, {Path, Module, Reason}, Warnings}`. Stats count written, skipped, and
deleted files. Build warnings pair a path with `{Location, Module, Reason}`.
Warning promotion is a CLI policy; library callers handle warnings themselves.

### Build details

Input must exist and input/output paths must be disjoint after normalization.
Mapped file/directory and destination collisions (for example `foo.erl` beside
`foo.erlx`) are checked before writes. Root, input-tree, and mapped-output
symlinks are rejected, as are special files and outputs hard-linked to inputs.
Existing file/directory type conflicts require explicit removal, even with
`--clean --delete`.

Timestamp comparisons have filesystem-second precision; same-time edits may
require `--clean`. Extended source is validated on every build even if its
output is current; unchanged plain files are not reread. Copies preserve bytes
and permission bits. Empty input directories are retained.

Deletion starts only after generation/copying succeeds. Extra symlinks are
unlinked as leaves, never followed; obsolete empty directories are pruned with
`--delete`. Each output is published through a private sibling and rename,
but the whole build is not transactional: failures can leave earlier writes
or deletions in place. Warnings alone exit successfully unless promoted.

CLI exit codes are `0` for success, `1` for source/I/O errors or promoted
warnings, and `2` for usage errors. Failed single-file transformations emit no
partial source; promoted warnings still allow successful source output.

### Editor details

Standard Erlang indentation settings apply, including `erlang-indent-level`,
`erlang-indent-guard`, and `erlang-argument-indent`. `TAB`, `RET`, `C-M-a`,
`C-M-e`, `C-c M-a`, `C-c M-e`, `C-c M-h`, `C-c C-q`, and Imenu use Angler-aware
indentation/navigation. Navigation stops at function heads, after preceding
exports/specs. Electric punctuation features that call the parent parser
directly are disabled locally. Highlighting is lexical; incomplete code is
handled on a best-effort basis.

Sending chooses the sole live Erlang shell, prompts if several exist, or uses
`angler-shell-buffer`; `C-u C-c C-e` explicitly chooses one. Pending shell input
must be cleared or finished first. Sending leaves the kill ring unchanged;
failed transpilation sends nothing. Buffer transpilation uses a separate
read-only output buffer and retains previous successful output on failure.

`angler-warnings-as-errors` makes warning outcomes fail in editor commands.
Set `angler-project-root` or use `C-u C-c C-k` to choose a build directory;
a containing `src_ex/` project is preferred by automatic discovery, followed
by Emacs's project root, a containing `rebar.config`, or the current directory.
`angler-build-arguments` supplies additional CLI flags. Cleanup/deletion is
never enabled automatically. Settings can be buffer-local in `angler-mode-hook`,
which runs after `erlang-mode-hook`.

### Implementation and encoding

The implementation uses Erlang's `erl_scan` with text, comments, and whitespace
retained, then structured token rewriting. It does not expand macros or parse
and validate the complete generated module; use `erlc` for that. Function-head
and type recognition use `erl_parse`; snippet output is checked with
`erl_parse:parse_exprs` without evaluation.

The pipeline is scanning, record/local-annotation rewriting, function-spec
generation, export generation, and emission. `ext_scan` provides a complete
token stream plus indexed significant tokens; `ext_forms` and `ext_syntax`
provide structural traversal. `ext_records`, `ext_types`, and `ext_exports`
perform the transformations; `ext_emit` concatenates token text. `ext_build`
and `ext_cli` provide project synchronization and command-line entry points.

Binary input defaults to UTF-8, with an initial UTF-8 BOM retained separately.
Use the encoding option for Latin-1; encoding comments do not select it
automatically. Character lists contain Unicode code points. UTF-16/UTF-32 and
invalid encoded bytes are unsupported; decoding errors return
`{error, {invalid_encoding, Encoding}}`. Lexical failures retain `erl_scan`'s
location/module/description information. Untouched text retains comments,
line endings, escapes, and EOF layout. Generated fragments can add new lines.

### Development commands

```sh
make                    # compile Angler
make demo               # transpile, compile, and run example/example.erlx
make test               # six EUnit suites plus Python CLI/build tests
make test-emacs         # optional Emacs ERT tests
make fmt                # rebar3 fmt -w for the configured file set
make clean              # remove _build

rebar3 compile
rebar3 shell
rebar3 eunit             # Erlang suites only
rebar3 as fast compile   # omit debug information
rebar3 fmt --check
```

Tests require EUnit and Python 3; editor tests also require Emacs and Erlang's
`erlang.el`. Rebar3 was tested with 3.24.0. Both build tools use
`_build/default/lib/angler/ebin`. `rebar.config` selects the six EUnit suites
explicitly so fixture modules are not treated as suites. `make fmt` formats
its configured source/test/snippet set; use `rebar3 fmt -w FILE` for other files.

For editor tests, override `EMACS` or `ERLANG_EMACS_DIR` if automatic discovery
does not find your installation. The prepared cloud environment activates its
local OTP installation with `. /workspace/.angler-tools/activate.sh`.

Tests cover lossless round trips, idempotence, rewrites, diagnostics, generated
code compilation/execution, CLI behavior, build mirroring, and editor commands.
The OTP 29 [native-record probe](example/native_probe.erlx) is a separate manual
compatibility example; it is not part of the OTP 27 test suite.

## Next milestones

1. [ ] **Eqwalizer option:** preserve local type assertions as checked casts
   behind an explicit flag. The macro interface and supported annotation
   positions still need to be settled; there is currently no `--eqwalizer` flag.
2. [ ] **Integration:** further integration hardening, an optional Rebar3 hook,
   and benchmarks. Golden tests, compilation tests, diagnostics, and the
   documentation already exist and will continue to improve.

General type inference, type checking, a formatter, optimization passes, and
exports based on naming conventions are outside the current scope. A friendlier
conditional syntax is an idea under consideration, not an implemented feature
or committed milestone. Source mapping remains postponed.
