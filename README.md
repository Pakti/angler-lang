# Angler

Angler is a proposed lightweight, conservative syntax extension for Erlang. It transpiles extended source into ordinary Erlang without introducing a new runtime or type checker.

> Status: milestones 1–6 implemented: lossless scanner/emitter, local exports,
> Snippet and CLI, Function types, Records, and Build mirroring. Eqwalizer and
> the remaining integration work are planned.

## Developing the prototype

Requires Erlang/OTP 27 (the tested version), including the compiler and EUnit,
and either Make or Rebar3 (tested with 3.24.0). The CLI launcher targets Unix-like systems with `/dev/stdin`.
Python 3 is needed for the CLI process tests; Emacs is optional for editor tests.
No application dependencies or running services are required. Rebar3 downloads
the pinned erlfmt 1.8.0 project plugin on first use.

```sh
make       # compile into _build/default/lib/angler/ebin
make test  # run EUnit and CLI process tests (requires Python 3)
make test-emacs  # optional: run Emacs integration tests with Emacs installed
make fmt   # format configured sources/tests/snippets via rebar3 fmt -w
```

To format a single generated file, run `rebar3 fmt -w example.erl`.
`make fmt` uses the file list in `rebar.config`, including `_snippets/*.erl`.
Formatting is optional and can change source line numbers; see
[Known limitations](#known-limitations) for `?FILE` and `?LINE` behavior.

Rebar3 is also supported directly:

```sh
rebar3 compile          # same application ebin path as make
rebar3 shell            # interactive shell with angler on the code path
rebar3 eunit            # Erlang test suites (not Python/Emacs tests)
rebar3 as fast compile  # compile without debug information
rebar3 fmt --write      # format the configured file set in place
rebar3 fmt --check      # check formatting without modifying files
```

Use `make test` for both EUnit and CLI process tests, and `make test-emacs`
for editor integration. There are no Common Test suites yet. `rebar.config`
selects the six EUnit suites explicitly so example fixture modules are not
mistaken for suites. Both build tools share the application output directory,
which is also used by `bin/angler`. Build again after changing source files.

In the prepared cloud environment, first run
`. /workspace/.angler-tools/activate.sh` in each shell to activate Erlang.
Run `bin/angler --help` after building, or add the checkout's `bin/` directory
to `PATH` to use the `angler` command from any working directory.
The prototype's own Erlang sources live in `src/`. Build mirroring is intended
for consuming projects with a `src_ex/` input tree; do not use this checkout's
handwritten `src/` as a generated output directory.

From `erl -pa _build/default/lib/angler/ebin` after compilation:

```erlang
Source = <<"% keep this comment\r\nf() -> ok.">>,
{ok, Document} = ext_scan:scan(Source),
Source = ext_emit:emit(Document),
Tokens = ext_scan:tokens(Document),
Significant = ext_scan:significant(Document).
```

`scan/1` returns `{ok, Document}` or `{error, Reason}`. `tokens/1` returns every
original `erl_scan` token, including comments and whitespace, with its text and
location annotations intact. `significant/1` returns `{Index, Token}` pairs,
excluding comments and whitespace; one-based indices point into the complete
stream. A `dot` token may itself contain trailing whitespace, as specified by
`erl_scan`; that text stays attached to the token. Documents are intended to be
passed between the scanner and emitter without changing their representation.

`emit/1` concatenates token text rather than formatting token values. Successful
scans preserve the input exactly, including empty input, trailing comments,
missing final newlines, LF/CRLF line endings, escapes, and Unicode text:

- Binary input defaults to UTF-8 and produces identical bytes. An initial UTF-8
  BOM is retained separately and restored on emission; token locations start
  after the BOM at `{1, 1}`.
- For Latin-1 bytes, use `ext_scan:scan(Source, latin1)`. Encoding declarations
  in comments are preserved but do not select the encoding automatically.
- Character-list input contains Unicode code points and emits the same list.
  The encoding argument only controls decoding and re-encoding of binary input.
- Invalid or incomplete encoded binaries return `{error, {invalid_encoding,
  Encoding}}`. Lexical failures return `{error, ErrorInfo}` using `erl_scan`'s
  location/module/description tuple. No partial document is emitted.
- UTF-16/UTF-32 and arbitrary invalid source bytes are unsupported. Scanning is
  lexical only: it neither validates whole-module syntax nor expands macros or
  includes. Compiler acceptance is checked separately in the tests.

The suite exercises both input representations, the indexed token view,
encoding and scanner errors, repository-source round trips and idempotence,
and compilation/execution of emitted Erlang using an include, record macros,
and `?LINE`.

### Transpiling local exports

The public API scans, expands exports, and emits source of the same type
(binary or character list):

```erlang
{ok, Erlang} = angler:transpile(
    <<"-module(example).\n_export\nstart() -> ok.\n">>).
```

`angler:transpile/2` also accepts `utf8` or `latin1`, with the same encoding
rules as `ext_scan:scan/2`. Scanner errors pass through unchanged. Directive
errors return `{error, {Location, ext_exports, Reason}}`; use
`ext_exports:format_error(Reason)` for a readable message.

Each `_export` at the beginning of a top-level form marks the immediately
following function, including all its clauses. Comments and whitespace may
intervene; attributes (including `-spec`), repeated directives, missing
functions, and unsupported heads produce diagnostics. Arity is determined from
the first function head with Erlang's parser, so nested patterns and guards are
handled structurally. The normal compiler remains responsible for validating
the complete function and consistency of its clauses.

The emitter removes only directive tokens and inserts one combined export
attribute immediately after `-module`, ahead of other attributes/includes and
function definitions. Module-less fragments use the first definition as the
insertion point; they still need a module declaration to compile. Existing
unconditional, literal `-export` entries are respected without adding duplicate
exports, and existing attributes remain byte-for-byte intact. Generated text
currently includes a separating space and adds no newlines. This is an
implementation detail, not a source-line preservation guarantee for transformed
code. Optional erlfmt formatting provides standard layout and can change line
numbers. See [Known limitations](#known-limitations).
Without directives, transpilation is an exact round trip; applying it again to
generated Erlang leaves the output unchanged. There is no export-by-name rule.

This milestone does not run the preprocessor: macros in bodies and ordinary
includes are preserved for the compiler. Macro-generated function names,
arguments, or guards on marked functions are not supported yet and produce
head diagnostics. `_export` inside `-ifdef`/`-ifndef`/`-if` branches is explicitly
rejected: use ordinary Erlang export attributes there. Exports supplied through
macros, includes, or conditional branches cannot be deduplicated against a
directive; avoid marking those functions again.

## Goals

- Attach types directly to function arguments and return values, avoiding separate `-spec` boilerplate.
- Mark exported functions next to their definitions instead of maintaining centralized `-export` lists.
- Use concise record field access and updates when a variable's record type is explicitly annotated.
- Keep the implementation in Erlang, small enough for ordinary Erlang programmers to understand and modify.
- Preserve existing Erlang source unchanged wherever possible, ideally byte-for-byte.

Angler is intended to be Erlang with a few syntactic conveniences, not a new language.

## Proposed syntax

### Inline function types

Angler input:

```erlang
birthday(P :: #person{}) :: #person{} ->
    P{age = P.age + 1}.
```

Generated Erlang:

```erlang
-spec birthday(#person{}) -> #person{}.
birthday(P) ->
    P#person{age = P#person.age + 1}.
```

Argument types and return types use Erlang's existing `::` notation. All annotations are optional; missing types are represented by `any()` when generating a specification. A function with no annotations generates no new `-spec`. Standard Erlang `-spec` declarations remain supported.

### Multiple function clauses

Each clause can have its own types. The transpiler collects one signature per clause and generates an overloaded specification, preserving relationships between arguments.

```erlang
convert(X :: integer(), Y :: atom()) :: binary() ->
    ...;
convert(X :: binary(), Y :: integer()) :: binary() ->
    ....
```

Generated specification:

```erlang
-spec convert(integer(), atom()) -> binary();
             (binary(), integer()) -> binary().
```

Missing annotations contribute `any()`. If every annotation is `any()`, no
`-spec` is generated. Partially annotated overloaded clauses retain their
`any()` fallbacks and produce a warning about potentially broad or overlapping
alternatives. The CLI prints warnings to stderr while returning success.
`angler:transpile_with_warnings(Source, Encoding)` returns
`{ok, Output, Warnings}`; the simpler `transpile/1,2` API returns only output.

An explicit `-spec` and **any inline function annotation** on the same name/arity
are an error, even if their types appear identical or the annotations are all
`any()`. The diagnostic identifies the function and both locations. Remove one
source of function specifications. Explicit specs without inline annotations
are preserved unchanged. Local annotations do not generate function specs and
will remain allowed alongside explicit specs.

For this milestone, only simple variable arguments may carry annotations;
unannotated tuple, list, binary, map, and record patterns remain supported.
Return annotations go before the optional guard. Types are validated using
Erlang's type parser, including unions, records, remote types, and function
types. Macro-expanded argument patterns cannot establish a generated arity and are
rejected on annotated functions; use an explicit spec. Macro types and type
constraints requiring explicit specifications are not implemented. Tokens removed from annotations leave comments and
whitespace intact; generated specs currently add no newlines, without a
source-line compatibility guarantee. Nested expression blocks
and guard alternatives are distinguished from top-level function clauses.

### Local export directive

`_export` applies to the immediately following function (all its clauses):

```erlang
_export
start() ->
    x_initialize().

x_initialize() ->
    ok.
```

Generated Erlang:

```erlang
-export([start/0]).

start() ->
    x_initialize().

x_initialize() ->
    ok.
```

Several `_export` directives can be collected into a generated export attribute.
Existing standard `-export` declarations are preserved. There is **no**
export-by-name convention. `_export` is lexically an Erlang variable, but its
special meaning is restricted to the beginning of a top-level form. Only
comments and whitespace may occur between the directive and its function;
intervening module attributes, including `-spec`, are errors.

#### Optional export tags (agreed design; not implemented yet)

A directive may optionally carry a **single atom tag**, in parentheses:

```erlang
_export(api)
start() ->
    ok.

_export(gen_server)
init(Args) ->
    {ok, Args}.
```

Plain `_export` remains valid and belongs to an untagged group. A function has
at most one tag; multiple tags and repeated directives are errors. Comments
and whitespace remain the only permitted content between the complete
directive and its function. Tags group output only: they do not change export
visibility, validate behavior callbacks, or introduce runtime metadata.

Generate one export attribute per group, with tagged groups labeled by comments:

```erlang
%% api
-export([start/0, stop/0]).

%% gen_server
-export([init/1, handle_call/3]).
```

Groups follow first-seen order; functions within each group follow source order.
The untagged group has no tag label. Existing standard export attributes remain
intact, and entries already exported are not duplicated by generated groups.
Generated comments may add lines; output can be normalized with erlfmt.
Source-line preservation is not a requirement for transformed extended syntax.
The current implementation supports only plain `_export`; tagged syntax is a
planned extension to the completed Exports milestone.

### Record fields and updates

Only explicitly record-annotated variables support abbreviated access.

```erlang
get_name(P :: #person{}) :: string() ->
    P.name.

birthday(P :: #person{}) ->
    P{age = P.age + 1}.
```

`P.name` becomes `P#person.name`; `P{age = ...}` becomes `P#person{age = ...}`. Ordinary Erlang record operations remain valid. No record-type inference or field-type checking is performed by Angler.

### Local annotations for nested records

```erlang
city(P :: #person{}) :: string() ->
    A :: #address{} = P.address,
    A.city.
```

Default generated Erlang:

```erlang
-spec city(#person{}) -> string().
city(P) ->
    A = P#person.address,
    A#address.city.
```

Angler maintains a simple mapping from explicitly annotated variable names to record names within each top-level function clause. Local annotations update it from the annotation onward, and the environment resets at the next clause. Full lexical scope and shadowing analysis are out of scope; programmers should avoid shadowing annotated variables. Conflicting annotations of the same variable should be reported. Initially, only simple local variable annotations need support, not annotations deeply nested in patterns.

By default local annotations are syntax hints: the generated Erlang does not retain their type assertions for a type checker.

Local bindings must be `Variable :: Type = Expression`, with a simple variable
at an expression boundary; annotations inside tuple/list patterns or anonymous
function heads are not supported. Ordinary Erlang types are accepted as syntax
hints, but only a direct record type such as `#person{}` enables shorthand.
Re-annotating a variable with a different type is an error; repeating the same
type is allowed. Missing record annotations produce diagnostics rather than
record-name inference. No record definitions or field-type checking are needed
by the transpiler; the standard compiler or shell checks actual record fields.

Header annotations seed a fresh environment for each top-level function clause.
Local annotations affect subsequent text within that clause (or the current
snippet), including nested expressions, and are removed before function-spec
conflict checks. They therefore remain usable alongside an explicit `-spec`.
There is no branch-flow or shadowing analysis: avoid shadowing annotated names,
and supply intermediate annotations for nested records. `P.address.city` is
rejected; use `A :: #address{} = P.address, A.city` instead. The field atom must
immediately follow its dot, as whitespace after a dot denotes an Erlang form
terminator. Comments/whitespace elsewhere are retained. The current rewrite
adds no newlines, but source-line preservation is not guaranteed.

## Optional Eqwalizer support

The default transpiler has no Eqwalizer dependency. A proposed `--eqwalizer` flag enables Eqwalizer-specific local type ascriptions. For example:

```erlang
A :: #address{} = get_address()
```

normally becomes `A = get_address()`; with Eqwalizer enabled it may become:

```erlang
A = ?CHECKED_CAST(get_address(), #address{})
```

The implementation must verify the exact supported Eqwalizer macro interface and include the required header as needed. This option must not change parsing or record-name resolution.

## Implementation approach

- Implementation language: Erlang.
- Scanner: `erl_scan`, retaining token text, comments, and whitespace.
- Translator: structured token rewriting, not regex replacement or a complete new parser.
- Emitter: concatenate original text for untouched tokens; replace only recognized extended syntax and insert generated attributes.
- Validate generated ordinary Erlang with the standard compiler.

Suggested scanner call:

```erlang
erl_scan:string(Source, {1, 1},
                [text, return_comments, return_white_spaces]).
```

Maintain two views: a lossless stream of text-bearing tokens (including whitespace and comments), and a filtered view of significant tokens for syntax recognition. Use the filtered view to drive transformations on the lossless stream. No separate formatter or original-source offset editor is planned for v1.

Recognize top-level forms and clauses from token structure, not source indentation. Distinguish nested `fun`, `case`, `receive`, and other expressions from function heads. Keep the implementation intentionally limited rather than attempting comprehensive Erlang semantic analysis.

Macros and macro expansions are assumed to contain **only standard Erlang syntax**. Ordinary macros and includes should continue to work; the order of preprocessing versus rewriting must be tested.

### Suggested modules

| Module | Responsibility |
| --- | --- |
| `ext_scan` | Tokenization and token views |
| `ext_forms` | Top-level forms, functions and clauses |
| `ext_types` | Function and local annotations |
| `ext_records` | Abbreviated record operations |
| `ext_exports` | `_export` |
| `ext_specs` | Overloaded specifications |
| `ext_emit` | Output with token/text preservation |
| `ext_cli` | CLI and optional backends |

Pipeline: tokenize; identify forms and clauses; collect types and exports; build per-clause record environments; rewrite extensions; insert attributes; emit ordinary Erlang.

## Project layout and build synchronization

Build mirroring is implemented by `angler build`. It treats
`src_ex/` as the authoritative source tree and `src/` as the generated output
mirror. Mapped output files may be overwritten during generation, so do not
keep valuable edits only in generated files. Extra output files are preserved
by default and removed only with an explicit `-d`/`--delete`. There is no output
ownership manifest, staging tree, or transactional publication.

Example:

```text
my_app/
  rebar.config
  src_ex/
    server.erlx
    protocol.erl
    settings.json
    include/types.hrl
  src/
    server.erl
    protocol.erl
    settings.json
    include/types.hrl
```

`angler build` recursively mirrors the input tree:

- `*.erlx` files are transpiled to corresponding `*.erl` files.
- **Every other file** is copied byte-for-byte, regardless of extension (including `*.erl` and extensionless files).
- The relative directory structure is preserved.
- Colliding destinations, such as `foo.erl` and `foo.erlx` in the same input directory, are build errors.
- Output files without corresponding inputs are extras: warn for each extra
  and leave it untouched by default. `-d`/`--delete` removes extras and the
  output directories made empty by that deletion, only after all generation
  and copying operations succeed. Do not follow output symlinks when deleting.
- `src_ex/` must exist; missing input is an error, not an instruction to empty `src/`.
- Input/output locations must not overlap, and `src/` must not be a symlink.

Angler handles incremental rebuilds using file modification times; GNU Make
is not required. Missing or outdated mapped outputs are generated or copied;
up-to-date outputs are left untouched. The agreed build options are:

| Option | Behavior |
| --- | --- |
| No cleanup flag | Incrementally generate/copy mapped files; warn about extras and preserve them. |
| `-d`, `--delete` | Also delete extras and resulting empty directories after generation/copying succeeds. |
| `--clean` | Force regeneration/recopying of every mapped output, regardless of timestamps. Preserve extras unless `--delete` is also supplied. |
| `--clean --delete` | Force regeneration and remove extras, producing an exact mirror on success. |

Use `--clean` when the transpiler version or options change. It does **not**
remove and recreate the entire output tree, and never implies `--delete`.

**Warning policy:** warnings alone leave
the exit status at zero. `--warnings-as-errors` applies to all transpiler
warnings, including extras and partially annotated overloads: display the
warnings and return a nonzero exit status. It does not imply deletion or grant
permission to remove extras. Promotion changes the exit status, not the
publication policy: successful writes and deletions requested with `--delete`
remain, and successful single-file output is still emitted to stdout.

**Failure semantics:** a generation, copy, or deletion failure returns nonzero.
Generation/copy failures prevent the deletion phase, but already written
outputs can remain: v1 provides no rollback or staging. Warning promotion is an
exit-status policy, not a transactional guarantee. Without `--delete`, a
successful build may retain extras; with `--delete`, successful synchronization
leaves precisely the files mapped from `src_ex/`.

Mapped files are planned before any output writes; name collisions and
file/directory collisions fail that preflight. Input and output paths must be
disjoint after dot-segment normalization. Symlinks in root paths, input trees,
and mapped output paths are rejected. Extra output symlinks are warned about
or unlinked as leaves, never followed. Special file types are unsupported.
An existing output file/directory type conflict is an error, even with
`--clean --delete`; remove the blocking entry explicitly. A mapped output
hard-linked to its input is also rejected. Empty input directories are retained;
obsolete empty output directories are warned about or pruned with `--delete`.

Only missing or older mapped outputs are written, unless `--clean` is supplied.
Timestamp comparison has filesystem-second precision; same-time content edits
may require `--clean`. Extended source is validated on every build so warnings
and errors are still reported when output writes are skipped. Unchanged plain
files are not reread. Copies preserve their bytes and permission bits. Each
file is published through a private sibling followed by rename, avoiding
partial individual files; this does not make the whole build transactional.

## CLI and snippet transpilation

The implemented CLI uses the core API, with separate module and expression
entry points:

| Command | Purpose |
| --- | --- |
| `angler transpile path/to/file.erlx` | Transpile one file to stdout, including exports, specs, and record shorthand. |
| `angler snippet` | Transpile local annotations and record shorthand in an expression sequence from stdin. |
| `angler --version` | Print the version. |
| `angler --help` (or `-h`) | Print usage and current limitations. |
| `angler build [--clean] [--delete]` | Incrementally synchronize `src_ex/` into `src/`; extras are preserved by default. |

`transpile` and `snippet` accept `--encoding utf8|latin1` (UTF-8 by default).
Use `--` before filenames starting with `-`. File arguments are relative to the
caller's working directory; input files are never changed. Capture output with
shell redirection to a **different** path:

```sh
angler transpile example.erlx > example.erl
angler transpile --encoding latin1 -- -example.erlx > example.erl
printf 'X = 40, X + 2.\n' | angler snippet
```

Snippet mode targets one expression sequence terminated by a period, ready
for the Erlang shell. Empty or comment-only input is also preserved. It uses
the same scanner/emitter as module transpilation, validates with
`erl_parse:parse_exprs`, and never runs the module export pass or evaluates any
code. Module declarations, function definitions, and `_export` directives
are not supported in snippets. Ordinary variables named `_export` remain valid.

The corresponding library APIs preserve the input representation:

```erlang
{ok, Output} = angler:snippet(<<"X = 40, X + 2.\n">>),
{ok, Latin1Output} = angler:snippet(<<"42.">>, latin1).
```

Local annotations and abbreviated record operations are implemented in snippets:

```sh
printf 'P :: #person{} = get_person(), P.name.\n' | angler snippet
```

This emits ordinary Erlang equivalent to
`P = get_person(), P#person.name.` while retaining original whitespace and
comments. Snippets never generate module-level specs or export attributes.
The shell must already know record definitions; Angler does not inspect shell
bindings. Ordinary `P#person.name` syntax also passes validation without requiring
record definitions in the transpiler. Eqwalizer-specific casts remain deferred.

On successful source commands, stdout contains only source bytes, with comments,
encoding, BOMs, line endings, and EOF preserved. Diagnostics go to stderr, with
file/stdin location where available. Exit codes are `0` for success, `1` for
input/transformation/output errors, and `2` for usage errors. Input and
transformation failures emit no partial source. Module transpilation remains
token rewriting with type, export, and record passes; use `erlc` to validate the generated module.

Build accepts `--input DIR` and `--output DIR` (defaults: `src_ex` and `src`),
`--clean`, `-d`/`--delete`, and `--encoding utf8|latin1` for extended source.
Ordinary files, including `.erl`, are copied without decoding. All three source
commands (`build`, `transpile`, `snippet`) accept `--warnings-as-errors`.
Export tags and Eqwalizer remain unimplemented.

```sh
angler build
angler build --input source --output generated --clean
angler build --delete --warnings-as-errors
```

The corresponding library API is `angler:build()` or
`angler:build(#{input => "src_ex", output => "src", clean => false,
                delete => false, encoding => utf8})`. It returns
`{ok, Stats, Warnings}` with written/skipped/deleted file counters, or
`{error, {Path, Module, Reason}, Warnings}`. Warnings pair their source/output
path with `{Location, Module, Reason}`. The CLI applies warning promotion;
the library returns warnings for the caller to handle.

### Emacs integration

`angler-mode` is a major mode derived from the Erlang distribution's
`erlang-mode`. The initial mode setup associates `.erlx` files, inherits
Erlang's keymap, syntax table, indentation, highlighting and navigation, and
runs `erlang-mode-hook` followed by `angler-mode-hook`. Angler-specific
highlighting, indentation and navigation adjustments are still planned.

Ensure the Erlang distribution's `erlang.el` is on Emacs's `load-path`. If your
installation has not configured this already, add its `lib/tools-VERSION/emacs`
directory (or your distribution's Erlang-mode package directory). Then load
Angler using your checkout's path:

```elisp
;; Only needed if erlang.el is not already on load-path:
(add-to-list 'load-path "/path/to/otp/lib/tools-VERSION/emacs")
(load-file "/path/to/angler-lang/emacs/angler.el")
(setq angler-program "/path/to/angler-lang/bin/angler")
```

New `.erlx` buffers select `angler-mode` automatically. For an already open
buffer, use `M-x angler-mode`. The mode leaves ordinary `.erl` associations and
the source buffer contents unchanged. Customize Angler-specific settings in
`angler-mode-hook`; existing `erlang-mode-hook` customization still applies.
The copy helper can also be used without enabling the major mode.

Select an expression sequence and run `M-x angler-copy-snippet`. It invokes
`angler snippet` using UTF-8, copies successful output to the kill ring, and
leaves the source buffer unchanged. Paste the result into an Erlang shell.
Failures display `*Angler diagnostics*` and leave the kill ring unchanged.
Build with `make` first and ensure `erl` is available to Emacs through `PATH`.
A future command may send the output directly to the running Erlang shell.

`make test-emacs` discovers the parent mode under Erlang's tools application.
If it is installed elsewhere, set `ERLANG_EMACS_DIR=/path/to/erlang-mode` when
running the target. `EMACS=/path/to/emacs` selects the Emacs executable.

A Rebar3 pre-compile hook can run `angler build`; Rebar3 integration is optional rather than a required part of the transpiler.

## Compatibility and tests

**Vanilla Erlang identity is a central requirement.** For supported source files containing no extensions, the preferred invariant is:

```erlang
emit(scan(Source)) =:= Source.
```

Verify byte-for-byte round trips where possible, including whitespace, comments, encoding, line endings, and EOF behavior. As a fallback diagnostic, compare scanned token sequences with location metadata removed, retaining comments and values. Note that source-location-sensitive macros such as `?LINE` warrant special tests.

Other tests should cover inline types, overloaded clauses, incomplete annotations, `_export`, record fields and updates, local annotations, comments and strings containing extension-like text, macros, compiler acceptance, and optional Eqwalizer output. Directory tests should cover copied non-`.erlx` files, nested paths, collisions, deleted inputs and output cleanup, incremental timestamps, and failed-build behavior. Snippet tests should cover stdin/stdout, local annotations, diagnostics, and shell-ready output.

Generated ordinary Erlang should be idempotent under transpilation:

```text
transpile(transpile(Source)) == transpile(Source)
```

Benchmark scanner, rewriting, emitter, total time, and startup cost on modules of varying sizes before considering a different implementation language.

## Known limitations

- `?FILE` and `?LINE` are left to Erlang's preprocessor. The transpiler does not
  replace them with values relative to the original `.erlx` source. Such
  handling, including macros, includes, and `-file` attributes, is postponed.
- Byte-for-byte preservation applies to supported ordinary Erlang without
  extensions. Transformed extended syntax has no source-line preservation
  guarantee. Compiler diagnostics, stack traces, and `?LINE` can refer to the
  generated layout; `?FILE` normally identifies the generated `.erl` file.
- Running erlfmt on generated output may change line numbers further. Users
  who depend on its current line layout should avoid formatting that output.
  Avoiding erlfmt does not establish original `.erlx` filenames or guarantee
  original source line numbers. Source mapping remains future work.

## Deliberately out of scope for v1

- New conditional expressions such as `cond`.
- Type inference or type checking inside Angler.
- General lexical scope analysis or support for shadowing annotated variables.
- Extended syntax inside macro definitions or expansions.
- Automatic exports based on function naming.
- A formatter or sophisticated optimization passes.
- Supporting every unusual Erlang construct with extended syntax.

## Development milestones

1. [x] **Lossless round-trip (implemented):** scanner and emitter; byte-for-byte preservation with documented encoding boundaries.
2. [x] **Exports (implemented):** plain `_export` and generated export attributes. Optional tagged groups are an agreed, pending enhancement.
3. [x] **Snippet and CLI (implemented):** stdin/stdout expression validation and preservation, single-file transpilation, and basic Emacs Erlang-mode integration. Originally moved ahead of types and records; record snippet rewriting is now implemented.
4. [x] **Function types (implemented):** inline annotations and multi-clause overloaded `-spec` generation.
5. [x] **Records (implemented):** local annotations, field access, and updates, including in snippet mode.
6. [x] **Build mirroring (implemented):** recursive synchronization, arbitrary-file copying, timestamps, collision detection, default warnings for extras, opt-in `-d`/`--delete`, force regeneration with `--clean`, and `--warnings-as-errors`.
7. [ ] **Emacs support:** an `angler-mode` major mode derived from the Erlang distribution's `erlang-mode`, with `.erlx` association, highlighting, indentation and navigation for extended syntax; source-preserving transpile/copy/send commands and compilation integration, covered by ERT tests. Mode setup (inheritance, `.erlx` association, hooks, and buffer-local customization) and `angler-copy-snippet` are implemented and tested. Angler-specific syntax behavior, additional commands, and direct shell sending remain planned.
8. [ ] **Eqwalizer option:** checked local annotations behind an explicit flag.
9. [ ] **Integration:** golden tests, compilation tests, diagnostics, optional Rebar3 hook, documentation, and benchmarks.

## Open design decisions

1. Resolved for Function types: only simple variable patterns may carry inline annotations initially.
2. Resolved for Function types: retain `any()` fallbacks and warn for incomplete overloaded signatures; use an explicit spec for precise contracts.
3. Resolved: explicit `-spec` plus inline function annotations on the same name/arity is an error, including identical types. Local annotations are independent.
4. Resolved for milestone 2: comments/whitespace may intervene between `_export` and its function; module attributes may not.
5. Which local annotation positions support checked Eqwalizer casts.
6. Source-relative `?FILE`/`?LINE` handling and source mapping are postponed; see Known limitations. Ordinary Erlang round trips remain lossless, while transformed extended syntax has no line-number guarantee.

These decisions should not block the initial scanner/emitter prototype.

## Design principle

Prefer small, explicit, predictable transformations over compiler sophistication. Angler should help Erlang programmers write and read ordinary Erlang programs with less ceremony, while leaving semantics and verification to the existing Erlang toolchain.
