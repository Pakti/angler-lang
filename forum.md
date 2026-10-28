I'm vibe-coding a preprocessor that adds a little syntactic sugar to Erlang, aiming to reduce some of the repetition and verbosity that irk me when reading code. I've chosen to implement it as a preprocessor so that the generated Erlang files remain available and usable even if the project becomes abandonware.  The code has been tested with Erlang/OTP version 27 and 29 on Linux.

The goal is to keep the extensions small enough that the code still feels familiar to Erlang programmers.

The preprocessor currently supports the following (see the code example below):

- `_export` before a function, optionally with a tag to group the generated export attributes.
- Inline function type annotations that generate `-spec` declarations, including overloaded specs.
- Shorter record field access and updates, using explicit annotations or simple local record-name deduction.
- A command-line interface with piping support.

As a source transformation tool, it has some limitations:

- No general type inference or type checking -- I'm using Eqwalizer for that.
- No extended syntax inside macros, at least for now.
- No guarantee that `?FILE` or `?LINE` will refer to the original source location.

For now, users are supposed to format the generated code with an external took like `erlfmt`.

I've also created a dedicated Emacs mode, derived from Erlang Mode, with commands to send a region to an Erlang shell after preprocessing it.

Here's a small example input file, to be saved with the `.erlx` extension:

[example omitted]

And here's the preprocessed code, formatted by `erlfmt`, with the original comments preserved:

[output omitted]

I'm trying to keep the scope limited. The only other features I'm currently considering are:

- Support for Eqwalizer's local type annotations, i.e. the `?CHECKED_CAST` and `?UNCHECKED_CAST` macros.
- Possibly a friendlier conditional construct to avoid the awkwardness of using `case` with `true` and `false`.

The project is still in alpha: https://github.com/Pakti/angler-lang

Any feedback is welcome.  Thanks!
