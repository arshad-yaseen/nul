# Changelog

## [Unreleased]

The language is being redesigned around union types. A type may be several
types, and a branch that settles which one narrows the value to it, so
optionals, errors, and sum types stop being three features and become one.
This release strips what that design replaces, so the rest is built rather
than retrofitted.

- Optionals `?T` and error unions `!T` are gone, along with the one universal
  error set and the `error Name` declaration. `T | none` is the first and
  `T | SomeError` is the second, and neither wraps the value it carries.
- `try`, `catch`, `orelse`, `null`, and the `|v|` capture go with them. One
  operator, `or`, takes over from the first three.
- `while` is gone. `loop` replaces it.
- `struct X { }` is now `type X = { }`. One keyword declares a type, and what
  stands after the `=` says which kind it is. A generic still writes its
  parameters before the `=`, as `type Box[T] = { }`.
- A struct literal names the type it builds, as `Point.{ x: 1 }`. The bare
  `.{ }` is gone, and with it the rule that a union in a type annotation could
  not say which member a literal meant. `E0216` retires.
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
- The help for a size cycle suggests breaking it with `*T`, and no longer
  with `?*T`, which stopped being syntax when optionals left.
- `type Name` with nothing assigned declares a unit type, whose only value
  is its name. `type none` and an error such as `type Timeout` are both
  this and nothing more.
- A type may be a union, written `A | B` wherever a type is written.
  Members are distinct types, order is part of the type, and a member that
  is itself a union flattens in place, so aliases compose. A repeated
  member is refused with `E0254`, and a union past 255 members with
  `E0255`.
- A value whose type a union lists becomes the union wherever the union is
  asked for: at `return`, an argument, a field, or an annotated binding. A
  union value becomes a wider union the same way. Membership decides, and
  nothing is wrapped.
- `e is T` tests which member a union holds, and `e is not T` the
  opposite. `T` has to be one of the members: `E0256` refuses `is` off a
  union, and `E0257` a type the union does not list.
- A branch that settles an `is` narrows the tested name. `let` bindings
  and parameters only, in both arms, holding across `and`, and to the
  rest of the union where a member was denied. A `var` never narrows, so
  bind it to a `let` first.
- `e or f` on a union is the first member of `e`, or else `f`. `or 8080`
  substitutes, `or return` sends the rest up unchanged, `or e { ... }`
  binds the rest and handles it, and `or` on a bool stays logical or.
  `E0256` refuses the handler form off a union.
- An `or` that ends in `return`, `break`, or `continue` may stand as a
  statement, and what it proved holds for the rest of the block: after
  `r is u32 or return 0`, `r` is `u32`. A branch that leaves narrows the
  same way, so `if r is not u32 { return 0 }` leaves `r` a `u32`.
- Every commit on `main` that passes CI is now cross-compiled and published as
  a dev build, under the version it reports, at the `dev` tag. Numbered
  releases stay the only supported builds. Both channels ship an `index.json`
  naming the version, the commit, and every archive with its checksum.
- A build with no history to read reports `X.Y.Z-dev` where it used to report
  `X.Y.Z`, so a source tree unpacked without its `.git` no longer claims to be
  the release it still precedes.

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
