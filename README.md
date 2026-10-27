# Angler

Angler is a proposed lightweight, conservative syntax extension for Erlang. It transpiles extended source into ordinary Erlang without introducing a new runtime or type checker.

> Status: preliminary design specification (v0.1). No implementation is claimed yet.

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

Missing annotations contribute `any()`. If the entire specification consists only of `any()` types, no `-spec` is generated. Partially annotated clauses may create overlapping or overly broad alternatives: the transpiler should warn, and the exact fallback policy is still open. Existing explicit specifications remain an escape hatch; conflicts with generated ones must be diagnosed.

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

## Compatibility and tests

**Vanilla Erlang identity is a central requirement.** For supported source files containing no extensions, the preferred invariant is:

```erlang
emit(scan(Source)) =:= Source.
```

Verify byte-for-byte round trips where possible, including whitespace, comments, encoding, line endings, and EOF behavior. As a fallback diagnostic, compare scanned token sequences with location metadata removed, retaining comments and values. Note that source-location-sensitive macros such as `?LINE` warrant special tests.

Other tests should cover inline types, overloaded clauses, incomplete annotations, `_export`, record fields and updates, local annotations, comments and strings containing extension-like text, macros, compiler acceptance, and optional Eqwalizer output.

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

1. **Lossless round-trip:** scanner and emitter; establish byte-for-byte preservation and document any exceptions.
2. **Exports:** recognize `_export` and emit export attributes.
3. **Function types:** inline annotations and multi-clause overloaded `-spec` generation.
4. **Records:** local annotations, field access, and updates.
5. **Eqwalizer option:** checked local annotations behind an explicit flag.
6. **Integration:** golden tests, compilation tests, diagnostics, documentation, and benchmarks.

## Open design decisions

1. Inline annotation grammar for literal and complex patterns.
2. Sound handling of partially annotated multi-clause specifications, especially overlapping `any()` overloads.
3. Conflict policy between existing and generated `-spec` declarations.
4. Whether comments or module attributes may intervene between `_export` and its function.
5. Which local annotation positions support checked Eqwalizer casts.
6. Precise whitespace and source-location compatibility guarantees.

These decisions should not block the initial scanner/emitter prototype.

## Design principle

Prefer small, explicit, predictable transformations over compiler sophistication. Angler should help Erlang programmers write and read ordinary Erlang programs with less ceremony, while leaving semantics and verification to the existing Erlang toolchain.
