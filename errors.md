# Errors

`memory.md` says where memory lives. This says how a program fails.

An error is an ordinary declaration, a set of them is an ordinary type, and a signature says
which set a function may fail with. Nothing is inferred across a call, nothing is converted,
and nothing is hidden.

## The contract

> **A function's errors are part of its signature. Widening is free, narrowing is checked,
> and the compiler writes the set for you.**

## Design axioms

Each one removes a class of pain that a real language is known for.

**E1. One representation.** Every error is one small integer, everywhere, forever. Two sets
never differ in layout, so widening from one to another is a retype and not a conversion.
This is the whole answer to Rust's plumbing tax, and it is a representation decision rather
than a type system decision.

**E2. A set is a constraint, not a layout.** `Open!File` and `!File` hold the same bytes. A set
says which values may appear, and says nothing about how they are stored.

**E3. Identity is the declaration.** `error NotFound` in two files is two errors. The pool
already keys an error value by `Decl.Index`, and this keeps it. Zig merges by name, so two
unrelated libraries can silently agree that their `FileNotFound` is one error. Nul refuses to
guess.

**E4. Nothing is inferred across a call.** A caller reads the callee's signature and never its
body. This is `region.md`'s A2, applied to errors, and it is not a stylistic preference.
`Compilation.ensure` returns early for a `.body` unit that is already in progress, because a
signature is all a call needs. Inferred error sets would make a signature depend on a body,
which needs a fixpoint over the call graph and turns every recursive function into a cycle.

**E5. Inference is a diagnostic, never a type.** The compiler computes the exact set a body
needs and tells you what to write. It never uses that number to type anything. This is how
the model gets Zig's ergonomics without Zig's opacity, and it is the centrepiece.

**E6. An error carries no payload.** Context travels through a parameter the caller owns,
where the region checker already proves it outlives the call. Part six argues this.

## Part one: an error is a declaration

Unchanged from today, and the ground everything else stands on.

```nul
pub error NotFound
pub error Denied
pub error Busy
```

A declaration is a name, a module, and a row. It is `pub` or not, it is imported like anything
else, and a missing one is reported by `findExported`. An error is a value, so it is raised by
naming it:

```nul
fn open(path: str) Open!File {
    if missing(path) { fail NotFound }
    return handle(path)
}
```

### Raising has its own word

An error name is an ordinary identifier, and in value position that is a problem to answer
rather than wave at. `return NotFound` tells a reader nothing. Worse, it misleads: an error is
PascalCase because it is a type, and a type in value position is refused everywhere else in the
language by `type_as_value`. The one place it is legal would be the one place it looks wrong.

So the site is marked, and the name is left alone:

> **`fail` raises an error. `return` returns a value.**

Three things follow, and only the first is about spelling.

**A name after `fail` is an error, always.** Nothing else may appear there, so a reader needs no
lookup and no convention. The other places an error name can be written already say what it is:
after `error` in a declaration, on the left of `!` in a type, and against a value that is
already an error in a comparison or a match arm.

**A failure is visible as a statement, not as a name.** `fail` marks the whole line, so the
error paths through a function stand out while reading, in a diff, and to `grep`. Zig's
`return error.NotFound` marks the name only, and costs eight more characters to do it.

**The vocabulary closes.** `try` takes an error out of a call and `fail` puts one in. Those two
words are every point where a program's error path enters or leaves a function, and both are
written down.

`fail` is a way out, like `return`, so it runs the defers on its path and is refused inside a
`defer` by `defer_cannot_leave`. It lowers to the `wrap_err` and `ret` that exist today, so the
IR gains nothing.

`return` still carries an error union, because that is a value: `return risky(n)` passes a
failure along without raising one, and widens the set on the way if it needs to. Only a bare
error is refused there, and the message names `fail`.

What was considered and lost. `return error.NotFound`, Zig's form, implies a global namespace of
errors, which E3 spends its whole argument refusing. `raise` and `throw` are the vocabulary of
unwinding, and nothing here unwinds. `.NotFound` would collide with the enum literal shorthand
the language will want later.

## Part two: `error` introduces the type, `type` still only aliases

Nul already draws a line between introducing a type and naming an existing one. `struct Point`
introduces a type and does not say `type`. `type Boxed = Box[i64]` names one that already
exists, and that is the only thing `type` has ever done.

An error set is a type, so `error` introduces it, for the same reason `struct` introduces a
struct:

```nul
pub error NotFound            // an error, and the set holding just it
pub error Denied
pub error Busy

pub error Open   = NotFound | Denied
pub error Access = Open | Busy          // sets compose, so a union of unions is a union
```

Every line in that block begins with `error`, which is the point. One keyword owns everything
an error is, and a reader looking for what can go wrong reads one kind of line.

### Why not `type`

`type Open = NotFound | Denied` was the first shape, and the argument against it is not the
obvious one. A set is structural, so `NotFound | Denied` is a type before anything names it,
and naming it really is aliasing. `type` survives that objection.

It does not survive the other two.

**`type X = A | B` already means something to a great many people, and it is not this.** It is
TypeScript's most recognisable idiom, where it builds a union of arbitrary types. Borrowing
that exact spelling for a form that accepts only errors takes a strong prior and breaks it.

**The promise it makes is permanently false.** The only sum types here are `?T` and `!T`, and
enums, when they come, will be nominal declarations rather than `type C = red | green`. So a
reader who tries `type Number = i64 | f64` is not early, they are wrong forever. A syntax that
invites a question whose answer is always no is worse than one that is never asked.

The parser agrees. Keeping `|` out of `parseType` means no precedence to settle against `!`,
`?`, and `*`, and no `fn f(x: A | B)` that parses before it is refused. Confined to
`parseErrorDecl` it is a flat list of paths, and no invalid program is reachable.

So **`|` is not a type operator.** It appears in exactly one place, on the right of an `error`
declaration, where both sides are always errors and the question never comes up.

This is not two spellings of one operation. `error X = A | B` takes only a union of errors on
its right, so `error X = i64` is not a thing that can be written, and `type Alias = Open` is
still there for ordinary aliasing. One constructs a set, the other renames a type.

### What a set is

Three properties, all of which fall out of interning:

- **Structural.** A set is its sorted, deduplicated member list, interned in the pool. Two
  declarations of the same members are one row, so `Open` and a hand written `NotFound |
  Denied` elsewhere are the same type, and `error Open = NotFound` is a plain rename.
- **Ordered by inclusion.** `outlives` has a twin. `subset(A, B)` is a merge of two sorted
  lists, and it is the only question the checker ever asks about a set.
- **Topped.** `error` names the universal set, the one every error belongs to. `!T` is
  `error!T` written short, so the bare form is not a special case in the checker, only in the
  parser. `fn name(e: error) str` is how a library takes any error at all.

There is no empty set. A function that cannot fail does not write `!`.

Duplicates are dropped in silence, because `Open | Busy` where `Open` already holds `Busy` is
ordinary composition rather than a mistake.

An error belongs to as many sets as you like. That is why a set does not own its members, and
why the grouped form, `error Open { NotFound, Denied }`, is not the design. It saves two lines,
it costs the ability to put one error in two sets, and it reads like Zig's form, which declares
its members rather than naming them.

A set is a type and not a value, so it cannot be raised. `fail Open` is refused by name.

### The grammar

```
decl  := 'pub'? 'error' name ('=' union)?
union := path ('|' path)*

type  := '*' 'var'? type
       | '?' type
       | '!' type            -- the universal set
       | 'error'             -- the universal set itself
       | path '!' type       -- a named set
       | path
```

`|` lives in `union` and nowhere else. In a signature the left of `!` is a path, so it is
`Open!File` or `io.Open!File`, and a set that is worth writing has a name by the time it gets
there.

A long set wraps after the `|`, because the newline rule already ends a statement after a name
and not after an operator. This is the rule arithmetic follows, and it needs no exception:

```nul
pub error Access = NotFound |
    Denied |
    Busy
```

A type parameter may stand on the left of `!`, checked once per instantiation, which costs no
code because instantiation is monomorphic already.

## Part three: the signature is the contract

The one rule with teeth:

> **`try e` inside a function returning `B!T` requires the set of `e` to be a subset of `B`.**

`return e` is the same rule, because a return coerces, and coercion is the subset test. So
there is one loop, run at two sites, and it reads only signatures.

| written | means | a caller may |
|---|---|---|
| `T` | cannot fail | nothing to handle |
| `!T` | may fail with anything | `try` it anywhere, handle it nowhere in particular |
| `E!T` | may fail with the members of `E` | `try` it wherever `E` fits, compare against `E` |

`!T` is the graceful default and costs nothing. It is what every program starts as, and it is
exactly today's behaviour. A set is opt in, and precision is paid for only where it is asked
for.

The cost is honest and worth stating: precision is viral downward. A function that promises a
narrow set can only `try` callees that promise a set inside it. Calling a `!T` helper from an
`Open!T` function is refused, because nothing proved the helper stays inside `Open`.

```nul
fn load(path: str, arena: Arena) Open!Bytes {
    let file = try open(path)          // Open ⊆ Open, fine
    return try read(file, arena)       // refused, 'read' returns '!Bytes'
}
```

The refusal is correct, the fix is mechanical, and part five removes the labour entirely.

### Widening is the second subtyping edge

`coerce` has exactly one subtyping edge today, `*var T` to `*T`, and it emits nothing. This
adds the second, and it emits nothing either:

```
A!T  ->  B!T     when subset(A, B)
X    ->  B!T     when X is an error and {X} ⊆ B, through wrap_err
T    ->  B!T     through wrap_ok, unchanged
```

Payload types must match exactly. Only the set widens.

Because both ends have the same layout, widening is a retype of a `Ref` rather than an
instruction. No `From`, no `map_err`, no newtype, no impl. This is the property Rust cannot
have, because there `Result<T, E1>` and `Result<T, E2>` are different shapes.

## Part four: handling

### The capture knows its set

`e catch |err| ...` binds `err` with the set of the caught expression, not with `error`. That
one change buys three things.

**Re-raising is checked.** `return err` inside the handler runs the same subset test as any
other return.

**An impossible comparison is refused.** Comparing against an error the expression cannot
produce is always false, and always a mistake:

```nul
let file = open(path) catch |e| {
    if e == Busy { retry() }           // refused, 'open' never fails with 'Busy'
    fail e
}
```

That catches the stale handler after an error is renamed or removed, which is the failure mode
Go's `errors.Is` cannot see and Rust's `match` catches only because it is exhaustive. The
precedent is already in the language: `while true` is refused as a constant condition, for the
same reason.

**Comparison stays two operators.** `==` and `!=`, between any two error sets, folded when both
sides are constants. Nothing else applies to an error.

### The shapes

Propagate, which is most of the time:

```nul
let file = try open(path)
```

Settle it here, which is most of the rest:

```nul
let file = open(path) catch fallback
```

Handle one case and pass the rest up, which is the interesting one:

```nul
let file = open(path) catch |e| {
    if e == NotFound { return try create(path) }
    fail e
}
```

Ignore it on purpose, which is visible and greppable:

```nul
write(file, data) catch {}
```

An error that goes nowhere is already refused, by `error_ignored`, and `_ =` does not silence
it. That rule stays exactly as it is.

## Part five: the compiler writes your sets

This is what makes the declared set design cost nothing to use.

While checking a body, the union of every set the body can raise is a byproduct of the checks
already running: the error constants it returns, and the sets of the callees it `try`s. It is
recorded per instance, and it is used for two things and never for a third.

**In a diagnostic.** When a `try` escapes the declared set, the help names the whole set the
body actually needs, as a declaration ready to paste:

```
= help: widen the set with 'error LoadFail = Open | Busy', or handle 'Busy' here with 'catch'
```

**In a command.** `nul errors <entry>` prints the minimal set of every function in the
program. The workflow is then: write `!T` everywhere, run the tool once, declare the sets at
the boundaries worth keeping stable.

**Never in a type.** The number is a body fact. Reading it to type a call would be exactly the
inference E4 refuses, and the checker does not.

So the labour of enumerating errors is the compiler's, and the contract is yours. Zig gives you
the first and not the second. Rust gives you the second and charges for the first.

## Part six: what an error does not carry

An error is an integer. It has no payload, no message, and no cause chain.

The temptation is real and the answer is no, for reasons specific to this language rather than
general:

- A payload makes `!T` a tagged union sized for its largest member, so every fallible function
  in the program pays for the worst error in its set.
- Reading a payload requires knowing which error you have, so it needs narrowing or a matching
  construct. The language has neither, and adding one for errors alone is the ad hoc
  abstraction `AGENTS.md` exists to prevent.
- A payload that holds a pointer is a lifetime, so a fallible function would inherit the result
  contract of `memory.md`, and a function with no arena could not fail informatively. Errors
  would stop being free to return from anywhere.

What replaces it, in ascending order of need:

**The name.** An error's name is a compile time fact, so the backend can emit a name table and
spend nothing until something asks. `main` returning `!T` uses it, below.

**A parameter the caller owns.** When a failure needs detail, the caller passes somewhere to
put it:

```nul
fn open(path: str, why: *var Report) Open!File
```

This is the pattern Zig reaches for and cannot prove. Here it is proven. `memory.md` already
requires that a function taking an arena and a `*var` parameter has its arena outlive that
parameter, and the region checker discharges it at the call. The detail cannot dangle.

**A library.** Anything richer, a cause chain or a formatted trail, is a `std` type built from
that parameter. The precedent is `memory.md`'s own: reference counting is a library type rather
than a language feature, written out at every use, and absent from a program that does not
import it. The core language inserts no code, ever.

## Part seven: what falls out for free

**No `errdefer`.** Zig needs it to free what a failing function allocated. Nul does not free.
An arena dies where it was declared, on the error path and the success path alike, and
`test/ir/defer.ir` already shows the deferred `arena_reset` re-emitted before each of three
returns. The feature has nothing to do.

**No interaction with regions.** An error is pointer free, so `holdsPointer` answers false for
a set and for an error union over a plain payload, exactly as `region.md` already assumes.
`wrap_err` and `unwrap_err` keep carrying `{forever}`. The region checker needs no change.

**Sets in generics, without generics over sets.** A type parameter may stand where a set does,
checked at instantiation like every other type argument. No bounds, no `where`, no variance.

**`main` may fail.** `pub fn main() !i64` becomes legal. The shim returns the value on success
and exits nonzero on failure, and once IO exists it prints the error's name from the table
above. Today a failing `main` is a broken C cast, which is the one real bug this design fixes
rather than adds.

**One C type per payload.** Two sets over one payload have identical layout, so the backend
names an error union by its payload rather than by its pool index. Widening then emits nothing
in C either, and a program with forty sets over `i64` still has one struct.

## Part eight: where this sits

| | plumbing | what can fail is visible | payload | exhaustive | cost |
|---|---|---|---|---|---|
| C | manual | no | out of band | no | none |
| Go | `if err != nil` at every call | no | yes, interface | no | interface |
| Rust | `From` impls, newtypes, crates | yes | yes | yes | none |
| Zig | none | inferred, so no | no | yes | trace |
| Swift | none | only since typed throws | yes | yes | unwinding |
| **Nul** | **none** | **yes, in the signature** | **no, by parameter** | **partly** | **none** |

The two columns Nul wins outright are the two that matter most in a large program: there is no
conversion work, and a signature tells the truth about what it can do. The column it concedes
is exhaustive handling, which part ten states plainly.

## Part nine: diagnostics

`region.md` reserves 237, 240, and 251 through 255. Errors continue from 256.

| code | name | fires at |
|---|---|---|
| E0256 | `error_escapes` | a `try` or `return` whose set is not inside the declared one |
| E0257 | `not_an_error` | a non-error named in a set, or a non-set on the left of `!` |
| E0258 | `impossible_error` | a comparison against an error the value cannot hold |
| E0259 | `private_error` | a public set naming an error private to its file |
| E0260 | `error_set_too_large` | more than `set_members_max` members |
| E0261 | `set_not_raisable` | a set where an error value belongs, such as `fail Open` |
| E0262 | `raise_needs_fail` | a bare error after `return`, which `fail` is for |

`try` in a function that cannot fail is already `try_needs_error_return`, and `fail` there is
the same mistake, so it reports under the same code with its own word in the message.

The escape message is the model's own sentence, both ends named, all three sites pointed at:

```
error[E0256]: 'read' can fail with 'Busy', and 'load' does not allow it
  --> load.nul:12:16
   |
12 |     return try read(file, arena)
   |                ^^^^^^^^^^^^^^^^ this can fail with 'Busy'
   |
   = help: widen the set with 'error LoadFail = Open | Busy', or handle 'Busy' here with 'catch'
note: 'load' promises 'Open'
  --> load.nul:10:34
   |
10 | fn load(path: str, arena: Arena) Open!Bytes {
   |                                  ^^^^ this set holds 'NotFound' and 'Denied'
note: 'Busy' is declared here
  --> lib.nul:5:11
   |
 5 | pub error Busy
   |           ^^^^
```

The help is the inferred set from part five, so the fix is a paste rather than a hunt.

## Part ten: what this refuses to do

Stated here rather than discovered later.

**One. No exhaustive handling.** Nothing checks that a handler covers every member of a set.
The language has no matching construct, and inventing one for errors alone would be a second
way to branch that nothing else in the language uses. What is caught instead is the other half,
the handler that names an error which cannot arrive, and that is the half that rots silently
during a refactor. The section below is why waiting costs nothing.

**Two. No anonymous sets.** There is no way to write a union in a signature, only a name that
was declared. A set worth writing is worth naming, the caller needs the name anyway to widen
its own, and keeping `|` out of type position is what stops the language promising union types
it does not have.

**Three. No cause chains, and no traces.** A failure knows what it is and not what it was
doing, and there is no runtime to hold a trace. Part six says where context belongs. The `try`
on every propagating line is the trace, and it is in the source rather than in a buffer.

None of the three is a soundness hole, and none of them is silent.

### What a match will add, and what it will not change

The concession above is a missing construct rather than a missing design. When matching
arrives, for enums or for anything else, error sets join it and nothing here moves.

```nul
let file = open(path) catch |e| match e {
    NotFound { return try create(path) }
    Denied   { return fallback }
}
```

Four things make that work, and three of them are already built.

**The cases are enumerable.** A set is a sorted interned list of declarations, read off the
signature of whatever was caught. The compiler can name every arm it is missing, because it
already knows the whole set before the body is walked.

**An arm may name a set, not only an error.** `Open` as an arm covers `NotFound` and `Denied`
together. Rust spells that `Err(NotFound) | Err(Denied)` and cannot name it. Here the group is
the declaration you already wrote, reusable and documented, and the check is that the union of
the arms holds the scrutinee.

**Exhaustiveness, redundancy, and an impossible arm are the same three set operations.**
Exhaustive is `subset(scrutinee, union of arms)`. An impossible arm is the rule `==` already
follows, so E0258 fires unchanged. Only overlap between two arms needs anything new, and that
is `setIntersect`, a merge over two sorted lists beside the three from part eleven.

**No payload means the weakest match is enough.** An arm binds nothing, destructures nothing,
and nests nothing, so errors need none of the hard parts of pattern matching. They will work on
the first day a match construct exists rather than waiting for its third version.

Two consequences worth stating now, because they shape what match should be.

**The universal set is not enumerable, so `!T` always needs a final arm.** There is no finite
list of every error a program might declare. Declaring a set is therefore what buys exhaustive
handling, and precision pays twice: once in the signature, once at the handler. That is the
right incentive and it costs no mechanism.

**`catch` should not grow arms of its own.** `catch |e|` binds, `match` dispatches, and the two
compose in the line above without either knowing about the other. Fusing them into
`catch { NotFound { } ... }` would buy one pair of pipes and cost a construct that only works
in one place.

The one seam to keep in mind: an arm here names a declaration, so it resolves like any other
name and must be in scope. If enums later gain a shorthand for naming a variant of the
scrutinee's type, errors will not use it, because an error is not a member of one type.

Five steps, each independently testable, in an order where nothing is half done.

**One. The pool.** `Key.error_set`, a sorted deduplicated run of `Decl.Index` in `extra`.
`Key.error_union` gains a set beside its child, so it moves to `extra` as two words. Then
`setContains`, `setSubset`, `setUnion`, bounded by `set_members_max`. `typeOfValue` of an error
value becomes its singleton set, which is what makes an impossible comparison visible on a
constant. Unit tests: interning canonicalises order and duplicates, subset against a naive
oracle, the bound exactly at, one below, and one above.

**Two. The grammar.** `parseErrorDecl` gains an optional `= path ('|' path)*`, under a second
node tag so the parser records which form it built. `parseType` gains an infix `!` after a
path, and `error` joins `starts_type` as the universal set.

`fail` is a keyword between `error` and `false`, which is where the tag list and the keyword
table both put it. It is not in `endsStatement`, because it always carries an operand. It joins
`starts_expr` and the arm of `parsePrefixExpr` that already handles `return`, `break`, and
`continue`, so it is an expression and `x orelse fail NotFound` works for free.

Cases in `test/parse-pass` and `test/parse-error`, including `|` refused in a `type`
declaration and `fail` with no operand.

**Three. The checker.** `Decl.Kind.error_set`, resolved by `declAsType` and refused by
`declAsValue`. The subset test at `try`, at `fail`, at `return`, and in `coerce`. `bindCaught`
binds the caught set instead of `error_type`. Comparison between sets handled before the mixed
types gate, because a member and its set are different pool rows and the generic path would
report the wrong thing. The inferred set accumulated per instance, for messages only.

`checkFail` is `checkReturn` with the operand required, the type required to be an error, and
`exitScopesDownTo(0)` before a `ret` of `wrap_err`. The `in_defer` refusal is the one
`checkReturn` already makes.

Cases in `test/fail` and `test/ir`, one per row of the table in part three and one per
diagnostic in part nine.

**Four. The backend.** Name an error union by its payload so widening stays free in C. The
error name table, emitted only when something reads it. `main` returning `!T`. Cases in
`test/emit` and `test/run`, including a program whose `main` fails.

**Five. The tool.** `nul errors <entry>`, printing the minimal set per function from the number
step three already computed.

The fuzzer needs three lines: a declared set in its header, a narrow signature among its
functions, and `e == SomeError` among its expressions.

## Errors in one page

- An error is a declaration, so its identity is its declaration and no two files can collide.
- `error` introduces a set the way `struct` introduces a struct. `type` keeps its one job,
  naming a type that already exists.
- A set is a sorted interned list of errors, combined with `|`, topped by `error`, and
  structural, so two declarations of the same members are one type.
- `|` is not a type operator. It appears only on the right of an `error` declaration, so the
  language never appears to offer union types.
- `fail` raises and `return` returns a value, so a name after `fail` is always an error, and a
  failing path is visible as a statement rather than hidden in an identifier.
- A signature carries the set. Nothing is read from a body, so the check is local, works across
  modules, and survives recursion.
- One relation, `subset`, one query, and one loop, run at `try` and at `return`.
- Widening is free because every error is the same integer, so there are no conversions, no
  `From`, and no newtypes.
- A capture knows its set, so re-raising is checked and an impossible comparison is refused.
- The compiler computes the exact set a body needs and puts it in the help, so precision is a
  paste rather than a hunt.
- An error carries no payload. Detail travels through a parameter the caller owns, which the
  region checker already proves outlives the call.
- No `errdefer`, because nothing is freed. No traces, because there is no runtime. No
  exhaustiveness, because there is no matching construct yet, and one error only for the
  handler that cannot fire.
