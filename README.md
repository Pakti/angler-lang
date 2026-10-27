# Angler

Angler is a proposed lightweight, conservative syntax extension for Erlang. It transpiles extended source into ordinary Erlang without introducing a new runtime or type checker.

> Status: milestones 1–5 implemented: lossless scanner/emitter, local exports,
> Snippet and CLI, Function types, and Records. Build mirroring and Eqwalizer
> remain design proposals.

## Developing the prototype

Requires Erlang/OTP 27 (the tested version), including the compiler and EUnit,
and Make. The CLI launcher targets Unix-like systems with `/dev/stdin`.
Python 3 is needed for the CLI process tests; Emacs is optional for editor tests.
No external Erlang dependencies or running services are required.

```sh
make       # compile src/*.erl into _build/test
make test  # run EUnit and CLI process tests (requires Python 3)
make test-emacs  # optional: run Emacs integration tests with Emacs installed
```

In the prepared cloud environment, first run
`. /workspace/.angler-tools/activate.sh` in each shell to activate Erlang.
Run `bin/angler --help` after building, or add the checkout's `bin/` directory
to `PATH` to use the `angler` command from any working directory.
The prototype's own Erlang sources live in `src/`; the proposed generated-mirror
workflow described below is not implemented and must not be run on this checkout.

From `erl -pa _build/test` after compilation:

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
includes a separating space but adds no newlines, preserving `?LINE` and all
original comments and line endings. Columns on the insertion line may shift.
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
whitespace intact; generated specs add no newlines. Nested expression blocks
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

Several `_export` directives can be collected into a generated export attribute. Existing standard `-export` declarations are preserved. There is **no** export-by-name convention. `_export` is lexically an Erlang variable, but is not a valid standalone top-level Erlang form; its special meaning is restricted to that position. Future Angler directives may use underscore-prefixed names where similarly unambiguous.

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
terminator. Comments/whitespace elsewhere are retained, and rewriting adds no
newlines.

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

Angler treats `src_ex/` as the authoritative source tree and `src/` as a **disposable, generated mirror**. Users must not keep valuable files only in `src/`; Angler may overwrite or delete any of its contents. There is no output ownership manifest, staging tree, or transactional publication.

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
- Output files without corresponding inputs are deleted, as are now-empty output directories.
- `src_ex/` must exist; missing input is an error, not an instruction to empty `src/`.
- Input/output locations must not overlap, and `src/` must not be a symlink.

Angler itself handles incremental rebuilds using file modification times; GNU Make is not required. Missing or outdated outputs are generated or copied; up-to-date outputs are left untouched to avoid unnecessary recompilation by Erlang build tools. A clean build is needed when transpiler version or options change.

**Failure semantics:** If any build operation fails, Angler exits nonzero. The contents of `src/` are then **not guaranteed to be consistent**. Users may clean `src/` and rebuild. For v1 there is no rollback, staging, or guarantee that a failed build preserves the previous mirror. An optional `angler build --clean` can remove and recreate the output tree.

On successful completion, `src/` contains precisely the mapped files from `src_ex/`, with no extras. Avoid following output symlinks during recursive cleanup.

## CLI and snippet transpilation

The implemented CLI uses the core API, with separate module and expression
entry points:

| Command | Purpose |
| --- | --- |
| `angler transpile path/to/file.erlx` | Transpile one file to stdout, including exports, specs, and record shorthand. |
| `angler snippet` | Transpile local annotations and record shorthand in an expression sequence from stdin. |
| `angler --version` | Print the version. |
| `angler --help` (or `-h`) | Print usage and current limitations. |
| `angler build`, `angler build --clean` | Planned build-mirroring commands; currently return an error. |

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

Build mirroring will later add `--input` and `--output`, defaulting to `src_ex`
and `src`. Those flags, directory synchronization, and Eqwalizer are not part
of the current CLI.

### Emacs integration

Load the supplied helper alongside Erlang mode, using your checkout's path:

```elisp
(load-file "/path/to/angler-lang/emacs/angler.el")
(setq angler-program "/path/to/angler-lang/bin/angler")
```

Select an expression sequence and run `M-x angler-copy-snippet`. It invokes
`angler snippet` using UTF-8, copies successful output to the kill ring, and
leaves the source buffer unchanged. Paste the result into an Erlang shell.
Failures display `*Angler diagnostics*` and leave the kill ring unchanged.
Build with `make` first and ensure `erl` is available to Emacs through `PATH`.
A future command may send the output directly to the running Erlang shell.

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

## Deliberately out of scope for v1

- New conditional expressions such as `cond`.
- Type inference or type checking inside Angler.
- General lexical scope analysis or support for shadowing annotated variables.
- Extended syntax inside macro definitions or expansions.
- Automatic exports based on function naming.
- A formatter or sophisticated optimization passes.
- Supporting every unusual Erlang construct with extended syntax.

## Development milestones

1. **Lossless round-trip (implemented):** scanner and emitter; byte-for-byte preservation with documented encoding boundaries.
2. **Exports (implemented):** recognize `_export` and emit export attributes.
3. **Snippet and CLI (implemented):** stdin/stdout expression validation and preservation, single-file transpilation, and basic Emacs Erlang-mode integration. Originally moved ahead of types and records; record snippet rewriting is now implemented.
4. **Function types (implemented):** inline annotations and multi-clause overloaded `-spec` generation.
5. **Records (implemented):** local annotations, field access, and updates, including in snippet mode.
6. **Build mirroring:** recursive `src_ex/` to `src/` synchronization, arbitrary-file copying, timestamps, collision detection, stale-output deletion, and clean builds.
7. **Eqwalizer option:** checked local annotations behind an explicit flag.
8. **Integration:** golden tests, compilation tests, diagnostics, optional Rebar3 hook, documentation, and benchmarks.

## Open design decisions

1. Resolved for Function types: only simple variable patterns may carry inline annotations initially.
2. Resolved for Function types: retain `any()` fallbacks and warn for incomplete overloaded signatures; use an explicit spec for precise contracts.
3. Resolved: explicit `-spec` plus inline function annotations on the same name/arity is an error, including identical types. Local annotations are independent.
4. Resolved for milestone 2: comments/whitespace may intervene between `_export` and its function; module attributes may not.
5. Which local annotation positions support checked Eqwalizer casts.
6. Precise whitespace and source-location compatibility guarantees.

These decisions should not block the initial scanner/emitter prototype.

## Design principle

Prefer small, explicit, predictable transformations over compiler sophistication. Angler should help Erlang programmers write and read ordinary Erlang programs with less ceremony, while leaving semantics and verification to the existing Erlang toolchain.
