# Nul Language Specification

> Signature sufficiency. A function's signature contains everything a caller needs. No language feature may make one function's type checking depend on another function's body. Any feature proposal that violates this is rejected or restricted until it does not.

## Comptime

Types are values. `let Node = struct { ... }` is an ordinary binding whose value is a
type, and anything that can name a type can be written where a type is expected.

A literal starts as `comptime_int` or `comptime_float`, and a known value flows with the
program: through arithmetic, which folds, and through names, since a `let` *is* the value
it was given. What folding proves is reported where it is written, in particular division
by zero and a result that does not fit where the operands settled.

`let` is comptime when its value is known. `var` is a runtime slot: its knownness ends at
the binding, and an untyped comptime initializer gives it `i64` or `f64`.

A known integer coerces to any integer or float type that holds its value, whatever width
it started at. A runtime integer widens implicitly and never narrows. Comptime integers
are 128 bits wide; a fold past that edge is an error, not a wrap.

`usize` and `isize` have no width yet, so only what every width shares is checked.
