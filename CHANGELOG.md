# Changelog

## [Unreleased]

The language is being redesigned around union types. A type may be several
types, and a branch that settles which one narrows the value to it, so
optionals, errors, and sum types stop being three features and become one.
This release strips what that design replaces, so the rest is built rather
than retrofitted. `demo.zol` is the design it is heading for.

- Optionals `?T` and error unions `!T` are gone, along with the one universal
  error set and the `error Name` declaration. `T | none` is the first and
  `T | SomeError` is the second, and neither wraps the value it carries.
- `try`, `catch`, `orelse`, `null`, and the `|v|` capture go with them. One
  operator, `or`, takes over from the first three.
- `while` is gone. `loop` replaces it.
- `struct X { }` is now `type X = { }`. One keyword declares a type, and what
  stands after the `=` says which kind it is. A generic still writes its
  parameters before the `=`, as `type Box[T] = { }`.
- `use` is now `import`.
- `!` before a value is now `not`. `!=` is unchanged.
- `E0217`, and `E0224` through `E0228`, retire.
- A declaration that writes more than 16 type parameters is now refused with
  `E0118` instead of crashing the compiler. A generic method inside a generic
  struct may hold 16 of its own on top of the struct's.
- A function body is always a block. The `fn f() T = expr` form is gone.
- `intrinsic` is a keyword. The standard library reaches the operations the
  compiler performs itself as `intrinsic.name[T](...)`, and `E0251` refuses it
  anywhere else.
- `intrinsic.ptr_cast[T](pointer)` retypes a pointer. It keeps what the
  pointer may do, so a read-only pointer cannot become one that writes.
- Bitwise operators `&`, `|`, `^`, `~`, `<<`, and `>>`, for integers. `&` is
  address-of before a value and bitwise and between two, told apart by where
  it sits, the way `-` already was.
- Compound assignment `+= -= *= /= %= &= |= ^= <<= >>=`, which reads its place
  once.
- `p.*` reads what a pointer points at, and is a place when the pointer is
  `*var T`.
- `a[i]` indexes, and carries type arguments where the base is generic.
- `defer` takes what a statement takes: a call, an assignment, or a block.
- A line that opens with `.` continues the line above, so a method chain may
  wrap across lines.
- Bitwise operators bind tighter than comparison, so `flags & mask == 0` groups
  as `(flags & mask) == 0`.
- A message names an operator the way source writes it. `'-' cannot be applied
  to bool`, not `'sub'`.
- A method without `pub` is private to its file, the way every other
  declaration already was.
- `-x` on the smallest value of a signed type reports that it does not fit,
  where it used to crash the compiler.

## [0.1.0] - 2026-08-04

Initial release. `zol` checks a program and prints its typed IR. Nothing runs yet.

### Language

- Structs with fields and methods, and generics written `[T]`.
- `let` and `var` bindings, `if`/`else`, `while`, and `defer`.
- `if`, `return`, `break`, and `continue` in value positions.
- Optionals `?T` and error unions `!T`, with `try`, `catch`, and `orelse`.
- Pointers `*T` to read through and `*var T` to write through.
- Arenas through `std.mem.Arena`, the only way to allocate.
- Modules are files, imported with `use` and exported with `pub`.

### Compiler

- Parsing with recovery.
- Demand-driven analysis, memoized per declaration.
- A typed control flow graph per function.
- Diagnostics with stable codes, spans, and suggestions.

### Command line

- `zol check <entry>` and `zol ir <entry>`.
- `--std <dir>`, `--color auto|on|off`, and `--version`.

[Unreleased]: https://github.com/arshad-yaseen/zol/compare/0.1.0...HEAD
[0.1.0]: https://github.com/arshad-yaseen/zol/releases/tag/0.1.0
