# Nul Type System

The complete type universe, the rules that relate types, and what the compiler must
decide about each one. This document supersedes the type annotations used casually in
`README.md` and `memory_model.md`; where they disagree, this wins.

Memory is not discussed here. Regions never appear in types, and nothing in this
document knows what an arena is beyond it being one more type. See
[memory_model.md](memory_model.md).

## What the rest of the language forces

Three constraints come from outside the type system and settle most of the arguments
before they start.

**Signature sufficiency** (`spec.md`). A function's signature contains everything a
caller needs, and no feature may make one function's checking depend on another's body.
This single rule rejects inferred return types, inferred error sets, `anytype`, and
duck-typed generics. It also means a generic body must be checkable at its
*definition*, not at each instantiation, which is why constraints below are mandatory
rather than optional.

**Everything is a value, aliasing is written down.** A type is a description of a value
and its layout. There is no identity separate from a value's bytes, so no hidden
indirection, no reference types, and no boxing that the type does not name.

**Regions handle lifetime.** The type system owes nothing to memory safety. It answers
two questions for the region checker and otherwise stays out of the way: *is this type
an arena*, and *is this type flat* (§10).

## What we take, and what we refuse

| From | Take | Refuse |
|---|---|---|
| Zig | types as comptime values, error unions, explicit allocation, no hidden control flow, arbitrary-width integers | `anytype`, inferred error sets, unbounded comptime, untagged unions by default |
| Rust | constrained generics checked at definition, exhaustive matching, no implicit conversion, newtypes | lifetimes, `&mut` exclusivity, coherence and orphan rules, `impl Trait` in return position, `Deref` chains |
| ML | sum types, exhaustiveness, inference inside bodies, no subtyping | global inference, higher-kinded types, runtime dictionaries |
| Ada | integer subranges as a first-class idea | the syntax, and the runtime check tax |
| Swift | protocol-shaped constraints, optional chaining | ARC, existential boxing |
| Go | a small type system ships | `interface{}`, lying zero values, runtime-dispatched interfaces |
| TypeScript | discriminated-union ergonomics, `never` | structural typing at scale, and the error messages it produces |
| C | a struct is its layout | everything else |

The pain points this system is specifically built to remove: null, integer casts,
overflow as undefined behavior, the `String`/`&str` split, the `Vec<T>`/`&[T]` split,
uninitialized reads, generic errors that point into a template, error-handling
boilerplate, and untagged unions.

## 1. Bindings and mutability

Two axes, kept strictly apart, because conflating them is the source of C's
`const` confusion.

```nul
let x = 3            // the binding never changes
var y = 3            // the binding may be reassigned
```

`let` and `var` describe the *name*. `*T` and `*var T` describe what you may do
*through a pointer*. They compose without interacting:

```nul
let p: *var Node     // p always points at the same Node, and you may write to it
var q: *Node         // q may be repointed, and you may only read through it
```

A value bound by `let` is immutable in full: its fields, and its elements, and
transitively any part of it reachable without a pointer hop. A pointer hop is where
immutability stops, because the pointer's own `var`-ness takes over. This is the whole
rule; there is no `const`-correctness to propagate by hand.

Assignment is by value (`memory_model.md` §1). The compiler may implement a copy as a
move or a borrow when the difference is unobservable.

## 2. No implicit initialization

A declaration with no initializer is illegal. Uninitialized storage must say so:

```nul
var buf: [64]u8 = undefined
```

Reading storage before it is assigned is a compile error, proven by
definite-assignment analysis over the IR's control-flow graph — which is one more
reason the IR exists before `nul check` finishes, not only before codegen.

There is no zero value for any type. A type that wants a default provides a named
constant, so the default is visible at the use site.

## 3. Primitives

```
void            zero-sized, exactly one value
never           uninhabited; the type of an expression that does not produce one
bool            true, false
i8 i16 i32 i64  isize
u8 u16 u32 u64  usize
iN uN           any width 1..65535, for packed layouts and bit protocols
f16 f32 f64     IEEE 754, no fast-math, ever, by default or otherwise
str             a UTF-8 view (§8)
type            the type of types; comptime only
Arena           an arena handle (see memory_model.md)
```

Comptime-only numeric types, for literals before they acquire a type:

```
comptime_int    arbitrary precision integer
comptime_float  arbitrary precision float
```

A literal has a comptime type until context gives it a concrete one, and the
conversion is checked exactly (`let x: u8 = 300` is an error at the literal, not a
truncation). A comptime numeric value may never reach runtime storage without a
concrete type.

`never` coerces to every type and inhabits none, so `fn abort() never` composes with
any expression and `match` arms that call it satisfy any result type.

## 4. Integers are ranges

The boldest decision here, and the one that removes the most friction.

**Every integer type is an inclusive range.** The named types are spellings for common
ranges:

```nul
u8   ==  0..=255
i32  ==  -2147483648..=2147483647
usize ==  0..=(platform word max)
```

A range is a type you can write directly, and so is a name for one:

```nul
let Percent = 0..=100
let Weekday = 1..=7

fn scale(p: Percent, n: u32) u32 { ... }
```

The storage width of a range type is the smallest integer that holds it. `0..=100` is
one byte. `Percent` and `u8` are *different types* with the same representation.

### What this buys

**Conversion by containment.** `A` converts implicitly to `B` when `A`'s range is
contained in `B`'s. This is the whole integer coercion rule, and it subsumes widening,
signedness, and every `@intCast` written to satisfy a compiler that already knew the
answer. Narrowing is not implicit, because it is not lossless.

**Bounds checks that vanish by typing.** A `for` over a range gives the index a range
type, so indexing needs no check and no annotation:

```nul
for i in 0..items.len {
    total = total + items[i]      // i : 0..items.len, so this cannot be out of bounds
}
```

Indexing `[N]T` requires an index whose range is contained in `0..N`. Indexing `[]T`
requires containment in `0..s.len`, which is a comparison against a value, so the
compiler either proves it, or requires you to handle failure:

```nul
let v = try items.at(k)          // k's range is not known to fit
```

**Overflow is a range violation.** Arithmetic produces the range implied by its
operands: `u8 + u8` has range `0..=510`. Storing that into a `u8` needs a narrowing,
which is exactly where an overflow would have been, so the compiler asks you to say
what you meant:

```nul
a + b       // range-checked: traps in debug, traps in release, never wraps silently
a +% b      // wrapping, result range is the destination's
a +| b      // saturating
try a + b   // yields an error instead of trapping
```

Where the compiler can prove the sum fits, all four are the same instruction and the
check is gone.

### The cost, stated plainly

Interval arithmetic is imprecise for multiplication, division, and shifts, and range
types on mutable storage would grow without bound across a loop. So the rule is:

> Ranges refine *expressions* and `let` bindings. `var` storage has a declared or
> inferred concrete type, and values narrow into it at assignment.

```nul
var i: usize = 0        // storage is usize, not 0..=0
i = i + 1               // fine, the sum's range fits usize
```

This is the pragmatic cut that makes the feature implementable with plain interval
arithmetic and no solver. If range types are ever cut for schedule reasons, keep the
`for i in 0..n` case: it is most of the value for a fraction of the work.

## 5. Aggregates

### struct

Nominal. Two structurally identical declarations are two unrelated types.

```nul
let Point = struct {
    x: i64
    y: i64
}
```

Layout is the compiler's to choose, including field reordering. Three modifiers make it
yours when it must be:

```nul
extern struct { ... }        // C ABI, declaration order, platform alignment
packed struct { ... }        // bit-level, iN/uN fields, no padding, defined bit order
align(N) struct { ... }      // stricter alignment
```

No inheritance. No implicit conversion between struct types, ever, in either
direction.

### union

**Tagged by default.** This is not a small thing: the untagged default is one of C's
worst inheritances, and Zig's `union(enum)` ceremony admits the default is wrong.

```nul
let Value = union {
    int:  i64
    text: str
    none: void
}
```

A tagged union carries a tag whose enum is generated from the field names and reachable
as `Value.Tag`. `match` over it is exhaustive:

```nul
match v {
    .int  => |n| use_number(n)
    .text => |s| use_text(s)
    .none => nothing()
}
```

A non-exhaustive `match` is an error, with the missing cases named. `else` is allowed,
and is the only way to write a `match` that survives a new variant.

`raw union { ... }` is untagged, requires `extern` or `packed` layout, and exists for C
interop and nothing else. Reading a field other than the last one written is undefined,
which is why it is spelled `raw`.

### enum

```nul
let Color = enum { red, green, blue }
let Status = enum(u8) { ok = 0, retry = 1, fatal = 255 }
```

Backing type is inferred as the narrowest that fits unless declared. An enum is *not*
an integer: conversion both ways is explicit. `match` is exhaustive.

`enum(nonexhaustive)` permits values outside the named set, for protocol fields whose
future values are not ours to enumerate.

### tuple

Structural and anonymous, for multiple returns and ad-hoc grouping.

```nul
fn divmod(a: i64, b: i64) .{ i64, i64 }
let .{ q, r } = divmod(7, 2)
```

Fields are positional. A tuple is not a struct and does not convert to one. If a return
value wants names, it wants a struct.

### distinct

A zero-cost nominal wrapper. The single cheapest defence against a whole class of bug.

```nul
let UserId = distinct u64
let Meters = distinct f64
```

`distinct T` shares `T`'s representation and *none* of its conversions. Unwrapping is
explicit. This is where units, identifiers, and handles live.

## 6. Optionals

```nul
?T
```

There is no null. A pointer is always valid; absence is `?*T`, which is
pointer-sized because the null representation is free. `?T` for other `T` costs a tag.

```nul
let name: ?str = lookup(k)

let shown = name orelse "anonymous"       // supply a default
if name |n| { print(n) }                  // bind if present
try name orelse error.Missing             // turn absence into failure
```

`T` coerces to `?T`. `?T` never coerces to `T`. `??T` is legal and distinct from `?T`,
because collapsing it is the mistake that makes "absent" ambiguous.

## 7. Errors

Failure is a value, in the return type, and never a hidden path.

```nul
let ReadError = error { NotFound, Permission, Corrupt }
```

An error set is a type. Sets compose by union:

```nul
let LoadError = ReadError | error { TooLarge }
```

An error union pairs a set with a success type:

```nul
fn read(arena: Arena, path: str) ReadError![]u8
```

**The error set is written, never inferred.** Inferring it would make a caller's
checking depend on the callee's body, which `spec.md` forbids outright. The cost is one
name per fallible operation; the return is that a signature is the truth, documentation
is complete, and a set change is a compile error at every caller rather than a silent
widening.

`anyerror` is the explicit opt-out. It accepts every error and gives up
exhaustiveness. It exists so prototyping is not painful, and it is visible in the
signature so its use is a choice.

```nul
let bytes = try read(arena, path)         // propagate; requires our set ⊇ callee's
let bytes = read(arena, path) catch &.{}  // supply a fallback

match read(arena, path) {
    .ok => |b| use(b)
    .err => |e| match e {
        .NotFound => create_default()
        .Permission, .Corrupt => report(e)
    }
}
```

`try` requires the callee's set be a subset of the current function's. That is checked
from the two signatures alone. There is no `From` conversion, no trait, and no
autoboxing: widening a set is a subset check, and it either holds or it does not.

`!T` with no set on the left is illegal. Absence of a set is not a shorthand for
anything.

`?T` is for absence and `E!T` is for failure. They are never conflated, and neither is
a substitute for the other.

## 8. Pointers, arrays, slices, strings

```nul
*T          single item, never null, read through
*var T      single item, never null, write through
[N]T        array; a value, N is comptime-known, copied on assignment
[]T         slice; pointer and length, read through
[]var T     slice, write through
[*]T        unknown length; C interop only
[*:0]T      unknown length, sentinel terminated; C interop only
```

Field access and method calls **auto-dereference exactly one pointer level**. This is
the one implicit operation in the language, it is bounded at one hop, and it is what
makes `tail.next = n` read the way it should. There is no user-extensible deref, no
chain, and no `Deref` coercion.

`[N]T` coerces to `[]T`. `*var T` coerces to `*T`, and `[]var T` to `[]T`. Never the
reverse.

There is no pointer arithmetic on `*T`. Walking memory is slicing, which carries a
length. `[*]T` supports arithmetic and exists to talk to C.

### str

```nul
str
```

A view of UTF-8 bytes: pointer, length, and a validity invariant. It is a *distinct
type*, not `[]u8`.

- `[]u8` → `str` requires validation: `try str.from_utf8(bytes)`.
- `str` → `[]u8` is free, because dropping an invariant always is.
- Indexing yields bytes. Codepoint and grapheme iteration are library functions, named
  so the cost is visible.
- No sentinel. `str.to_c(arena, s)` produces `[*:0]u8` when C needs one.

**There is no owned string type, and this falls out of the region model.** Rust needs
`String` and `&str` because ownership is a type-level property; Nul's ownership is the
arena, so there is one view type and `arena.dupe(s)` puts a copy wherever you need it.
The same argument kills the `Vec<T>`/`&[T]` split: `[]T` is the only slice type, and
`List(T)` is a builder that hands you one.

## 9. Functions

```nul
fn(i64, i64) i64                  a function type
fn(Arena, str) ReadError![]u8
```

Function values are pointers to code. There are no closures that capture implicitly: a
function that needs state takes it as a parameter, or is a method on a struct that
holds it. Capture would mean either allocation the signature does not name, or a
lifetime the type system does not track, and both are refused.

Parameters are `let` unless declared `var`, and a `var` parameter is a local copy. To
mutate the caller's value, take `*var T`.

Return type is always written. Inferring it is body-dependence.

## 10. Flatness

One predicate, consulted by the region checker and by `Arena.copy`.

> `flat(T)` holds when no value of `T` contains an access path to arena memory.

```
flat:      void, never, bool, all integers and ranges, all floats, enum,
           error sets, type-level values,
           fn (points at code, which outlives every arena),
           distinct T          if flat(T),
           [N]T                if flat(T),
           struct              if every field is flat,
           union               if every payload is flat,
           tuple               if every element is flat,
           ?T, E!T             if flat(T)

not flat:  *T, *var T, []T, []var T, [*]T, str, Arena
```

`Arena.copy(x)` requires `flat(@TypeOf(x))`. Copying a non-flat value between arenas
would relabel a pointer's region without moving what it points at, which is exactly the
invariant in `memory_model.md` failing.

Non-flat values move by rebuilding, and the standard library names the deep operations
so their cost is visible: `arena.dupe(s: str) str`,
`arena.dupe_slice(T: type where flat(T), s: []T) []T`. A type holding pointers gets no
deep copy for free, because there is no correct default for what a pointer should
become.

## 11. Generics and comptime

A generic is a function whose parameters include types.

```nul
fn List(T: type) type
fn max(T: Ord, a: T, b: T) T
```

Type parameters are comptime, evaluated at the call, and instantiations are memoized by
`(function, argument values)` so `List(i64)` names one type however often it is
written.

**Constraints are mandatory, and `type` is the top constraint.** `T: type` says nothing
is required of `T`, which is correct for containers that only store and hand back.
`T: Ord` says `T` provides what `Ord` requires. The constraint sits exactly where a
type annotation would, so there is no `where` clause and no second syntax to learn.

This is the point of the design: a generic body is checked **once, at its definition**,
against its constraints. An error in `sort` is reported in `sort`, at the line that is
wrong, in terms of the constraint that is missing. Not at the instantiation, not
fifteen frames into a template, and not differently for each caller. Signature
sufficiency demands it, and it happens to be the single largest ergonomic difference
between Rust's generics and C++'s templates.

Comptime is deliberately bounded. It may evaluate type expressions, fold constants, and
call functions that are pure and total. It may not perform I/O, allocate from a runtime
arena, or synthesize declarations. Evaluation runs against a fuel budget and reports
exhaustion as an ordinary error. Comptime is for computing types and constants, not for
metaprogramming — which is what keeps compile times bounded, errors legible, and
instantiations cacheable.

## 12. Interfaces

An interface is a named set of required declarations.

```nul
let Ord = interface {
    fn compare(self: *Self, other: *Self) Ordering
}
```

A type satisfies it by declaring those members in its own namespace. There is no
separate `impl` block, no coherence rule, and no orphan rule — a type is declared in
exactly one place, so the question of who may implement what never arises.

Dispatch is static. Nothing is boxed and nothing is allocated. When dynamic dispatch is
wanted, it is a type you write:

```nul
fn draw_all(shapes: []dyn Shape)
```

`dyn I` is a pointer and a vtable, two words, with the indirection visible in the type.

Operators come from interfaces rather than ad-hoc overloading: `==` requires `Eq`, `<`
requires `Ord`, `[]` requires `Index`. A type either declares the interface or does not
support the operator. There is no way to make `+` mean something surprising.

## 13. Type identity

**Nominal for declared types.** Each `struct`, `union`, `enum`, `error`, `interface`,
and `distinct` declaration creates a fresh type. Two identical declarations are
unrelated. This is what keeps error messages readable: types have names, and a mismatch
names them.

**Structural for constructed types.** `*T`, `?T`, `[]T`, `[N]T`, `E!T`, tuples, ranges,
and function types are equal when their components are. They are hash-consed.

**Aliases are not types.** `let a = Arena` binds a name to a type value. Both spellings
evaluate to the same interned type, so `arena: a` and `arena: Arena` and
`arena: mem.Arena` are one parameter type, and nothing downstream can tell them apart.
This is the entire answer to alias resolution: intern by identity, and spelling stops
existing after evaluation.

**No subtyping.** No variance, no `Any`, no upcasting. The only relations between
distinct types are the coercions in §14.

## 14. Coercion, complete

Implicit conversion happens in exactly these cases and no others. That the list is
closed and short is itself a feature.

| From | To | Condition |
|---|---|---|
| range `A` | range `B` | `A ⊆ B` |
| `comptime_int` / `comptime_float` | any numeric | the value fits exactly |
| `T` | `?T` | — |
| `T` | `E!T` | — |
| `E1!T` | `E2!T` | `E1 ⊆ E2` |
| `E1` | `E2` | `E1 ⊆ E2` (error sets) |
| `*var T` | `*T` | — |
| `[]var T` | `[]T` | — |
| `*[N]T` | `[]T` | — |
| `[N]T` | `[]T` | — |
| `never` | any | — |
| enum literal `.x` | enum or union tag | `x` is a member |
| anonymous struct literal | struct | fields match by name |
| anonymous tuple literal | tuple or array | arity and elements match |

Everything else is written: `@as`, `@int_cast`, `@ptr_cast`, `@bit_cast`, `@enum_from_int`,
`@int_from_enum`, `@float_from_int`. Named so that a reader can see which one is a lie
about bits and which is a checked narrowing.

Notably absent: no bool↔integer, no enum↔integer, no pointer↔integer, no float↔integer,
no `distinct T`↔`T`, and no struct↔struct.

## 15. Inference

Local and bidirectional. Never across a signature.

**Inferred:** the type of a `let`/`var` from its initializer; the type of a literal or
composite from its destination; comptime type arguments from runtime argument types,
when unification is unambiguous and needs no backtracking.

**Never inferred:** parameter types, return types, error sets, struct field types,
interface members, or anything else visible in a signature.

Sema is therefore two mutually recursive operations, and this shape should be built in
from the start:

```
infer(expr) -> Type            what does this expression produce on its own
check(expr, expected) -> ()    does this expression fit here
```

`check` is what makes `.{ x: 1 }`, `.none`, `&.{}`, and untyped literals work without a
turbofish. Every composite literal is checked against a destination rather than
inferred and then compared.

## 16. Deliberately absent

Each of these was considered and refused for a stated reason.

- **null** — `?T` is exact and costs nothing for pointers.
- **implicit initialization** — a zero value that means "unset" is a value that lies.
- **inheritance** — composition plus interfaces covers it without a layout contract
  between unrelated files.
- **exceptions, panics as control flow, RTTI** — hidden paths and hidden runtime.
- **implicit closures** — allocation or a lifetime the signature does not name.
- **inferred error sets, inferred returns, `anytype`** — body-dependence, forbidden by
  `spec.md`.
- **unbounded comptime** — unbounded compile times and unreadable errors.
- **untagged unions as the default** — the tag is nearly free and its absence is a
  memory-safety hole the region checker cannot see.
- **operator overloading outside interfaces** — `+` should never surprise.
- **subtyping and variance** — the complexity is real and the benefit is not.
- **`&mut` exclusivity, lifetime annotations** — regions do this job
  (`memory_model.md`).
- **structural typing for declared types** — it is why structurally-typed languages
  produce unreadable mismatches.

## 17. What the compiler needs

Directly relevant to the passes being built now.

**InternPool.** Types are `u32` indices. Primitives occupy fixed low indices so
`Type.Index.u8` is a constant and comparisons are integer equality. Structural types
are hash-consed on `(tag, operands)`. Nominal types are keyed on
`(declaration, comptime arguments)`, which is what memoizes `List(i64)`.

**Cached per type**, because they are asked constantly and computed recursively:
`flat`, size, alignment, `has_tag`, and whether the type is comptime-only.

**Two queries are the entire type-system surface the region checker uses:**
`ty == Type.Index.arena` and `flat(ty)`. Nothing else about types reaches it, which is
what keeps `memory_model.md`'s claim true that regions never appear in types.

**Order of work in Sema.** Signature typing precedes body checking and never consults a
body. Declaration-space evaluation is lazy and memoized with in-progress cycle
detection, since `let A = struct { b: *B }` and `let B = struct { a: *A }` must both
resolve. A cycle through a value field is an error and must name the field that closes
it; a cycle through a pointer is fine.

**Ranges are an interval per integer-typed IR value.** No solver, no symbolic
reasoning beyond comparing against a length that is already in scope. When an interval
cannot be proven to fit, the operation requires an explicit narrowing, and that is the
only failure mode.
