# Unions

Optionals, error handling, and sum types are three features in every
language we learned from, each with its own syntax, its own coercions, and
its own machinery. They describe one situation: a value that is one of
several things, and code that must find out which. Phi has the one
mechanism. A type may be a union of types, and a branch that settles which
member a value holds narrows the value to it.

```phi
type none
type Timeout
type NotFound

type Shape = Circle | Rect | Line       // the sum type
type Reply = Config | Timeout | NotFound

fn find(xs: List, want: u32) u32 | none // the optional
fn fetch(net: Net) Config | Timeout    // the fallible call
```

`T | none` is the optional, `T | E` is the fallible result, and a union of
unit types is the enum. Every rule added to unions improves all three at
once, and the price is that the one mechanism must be excellent, because
every shortcoming in unions is a shortcoming in three places.

Refused: separate optional and error types over a builtin sum, three
coercion systems for one idea. Exceptions, control flow the signature does
not show. Error sets, a second universe of types with its own inference
beside the one the language has.

## The three rules

Members are distinct types, and an alias is not a new type, so a repeat
through an alias is a repeat. To carry two values of one underlying type,
give each its own type, the honest cost of distinct members:

```phi
type Meters = { value: f64 }
type Feet = { value: f64 }

type Length = Meters | Feet             // f64 | f64 is refused
```

Order is part of the type, the way it is for a tuple: `A | B` and `B | A`
are distinct types, and the first member is the privileged one, the member
that succeeded. `or` splits it off, and a condition asks whether the value
holds it. Order is identity, not a wall: each of the two fits where the
other is asked, by membership, and what order changes is which member the
operators privilege.

A member that is itself a union flattens in place and may not introduce a
repeat, so aliases compose, and a named failure set splices into a
signature as its members:

```phi
type FileError = { code: i32 }
type BadSyntax = { line: u32 }
type LoadError = FileError | BadSyntax | Timeout

fn load(id: u32) Config | LoadError {   // four members, flat
    let raw = read(id) or return        // FileError leaves here, unchanged
    return decode(raw)
}
```

The alias is the one place a new failure is added, and every `match` over
it stops compiling until the new member has an arm. An alias may be
generic, and is still not a new type:

```phi
type Maybe[T] = T | none

fn head(xs: List) Maybe[u32] {          // exactly u32 | none
    ...
}
```

`Maybe[u32]` is `u32 | none` wherever either is written, and `Maybe[none]`
is refused, because substitution produced a repeat.

Refused: unordered member sets, which cost `or` and conditions their
meaning, since no member is first. Nominal variants with case names, a sum
type declaration, the fourth feature beside the three unions replace.
Nested unions as distinct types, an any-of algebra that answers no
question a program asks. Newtype semantics for aliases, which want the
conversions this language refuses to have; a distinct type is a struct
with one field, as `Meters` is.

## Membership, not conversion

What a signature permits is decided by membership and by nothing else. A
value whose type a union lists becomes the union wherever the union is
asked for, a union becomes a wider union that covers it, and nothing is
wrapped:

```phi
fn parse(raw: u32) f64 | BadNumber {
    if raw == 0 { return BadNumber }    // returning is just returning
    return to_f64(raw)                  // no wrapper, so nothing to learn
}

fn escalate(found: u32 | none) u32 | Timeout | none {
    return found                        // wider, by coverage
}
```

The only other implicit edge in the language is `*var T` fitting where
`*T` is asked. Nothing else converts: not integer widths, not floats and
integers, not anything, so there is no coercion lattice to learn, and
mixed arithmetic is an error that names both types. The other direction is
never free: a union gives a member back only through a branch that proves
it, so every unwrap is visible as control flow, which is what
[narrowing](narrowing.md) is.

Refused: numeric widening, which hides cost and decides silently what the
programmer should decide visibly. Constructors like `Some(x)`, ceremony
that restates what the signature already says.

## bool and the prelude

`bool` is a declaration, never built in:

```phi
pub type none

pub type true
pub type false
pub type bool = true | false
```

These four are the prelude, `std.prelude`, declared once and visible in
every file without an import. Unit types are nominal, so two files
declaring their own `none` declare two different types, and a `u64 | none`
could not pass between them; one shared declaration is what lets an
optional leave one module and be matched in another. The prelude is a
fallback, not a wall: anything nearer wins, so a file declaring its own
`bool` gets its own, and a program built without the standard library
declares the names by hand.

None of the four is built into the compiler. It finds `bool` by name where
a truth value is written, a comparison, an `is`, `and`, or `not`, refuses
to fold without one in scope, and asks for it nowhere else: a match's
member tests belong to the compiler and no program reads them. Because
`true` is the first member, `or` on a bool is ordinary union splitting
that happens to be logical or, and a condition on a bool is the ordinary
first-member question, one rule instead of two:

```phi
let truth = 1 < 2                       // a bool constant, folded
if truth { }                            // branches like any union
```

Refused: a builtin bool, which makes `or` two rules and puts a name in the
compiler the language cannot redefine. Per-file declarations as the
default, which read as simpler but make every file's optional its own
type, unable to cross a signature.

## Representation

A union value is stored as a tag and a payload, and the tag is not
something a program can name or read. The only questions a union answers
are membership questions, asked through `is`, `or`, `match`, and a
condition. What a program cannot observe, the compiler owns: tag width,
tag placement, and whether a stored tag exists at all are free choices,
and the 255-member cap fixes the worst tag at one byte.

A unit member occupies no payload bits, and a pointer is never null, so a
union of one pointer member and unit members hides its tag in the
pointer's forbidden values: `*T | none` is one word, with `none` spelled
as the zero no valid pointer holds. A member whose every bit pattern is a
value, an integer, leaves no room and carries the tag beside the payload.

```
type bool = true | false    one byte, the tag alone
u32 | Timeout | none        four payload bytes and a tag
*Node | none                one word, none is the zero
```

The saving compounds through every structure that links:

```phi
type Node = {
    value: u64
    next: *Node | none                  // one word, so Node is two
}
```

This is what the unobservable tag buys, and why the rule is absolute: the
optional-as-a-union costs what a builtin optional costs, without the
compiler knowing what an optional is.

Refused: an exposed discriminant, which locks the representation into the
ABI on the first day, invites integer casts that break when members
reorder, and buys nothing `match` does not already do.
