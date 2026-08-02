# The Surface Cleanup

`memory.md` is the model and `region.md` is its proof. This is the language surface: what
changes, what goes away, and what is still open. It folds into `spec.md` when the work is
done, and is deleted.

Two rules govern the work.

**One way to do each thing.** Where two spellings mean one idea, one of them goes, and the
survivor is the one that is harder to get wrong.

**Fresh, not retrofitted.** Nothing here is a compatibility shim. Where a construct is
replaced, its token, its node, and its checking code are deleted rather than left beside the
new one. A reader six months from now should not be able to tell that the old form existed.

**The grammar and the tree are held to the same standard as the model.** Nul's memory model
is one page because the model is small, and the front end has to earn the same sentence. So
the grammar is not allowed to accumulate: no production exists to work around another
production, no token exists that only one call site reads, and no node carries a field that
is meaningful for one tag in ten. Where a step would be easier by bending the grammar and
harder by fixing it, it gets fixed. Rewriting `Parse.zig` or reshaping `AST.zig` outright is
the expected cost of a step, not an escalation, and the tree that comes out is judged on
three things:

- **One shape per idea.** If two tags carry the same data and differ only in a keyword, they
  are one tag. If one tag means two things depending on a field, they are two tags.
- **The encoding is the documentation.** A node is `main_token` plus two payload slots whose
  meaning the tag decides, and the tag names the idea a person would name. A reader who knows
  the language should be able to predict the tree without reading the parser.
- **Errors are part of the grammar, not a fallback.** Every production knows what it is in
  the middle of, so a failure names the construct and points at the token that broke it.
  Recovery is designed with the production, not bolted on after.

## Part one: errors

### Errors are declarations

Today an error springs into existence at its use, so there is nothing to misspell against.
`if err == error.TooRiskyy { }` compiles and is quietly never true.

```nul
error NotFound
pub error PermissionDenied
```

Identity is the declaration, so two files each declaring `NotFound` hold different errors,
exactly as two files each declaring `struct Point` hold different types. Names are used
bare, so resolution, spelling suggestions, `pub`, `use` re-export, and the shadow rules all
arrive from machinery that already exists. The `error` keyword survives only where it
declares.

**Deleted:** the `error.X` expression form, its node tag, and its parsing.

The identity is the declaration itself. `Pool.Key.error_value` holds a `Decl.Index`, so
nothing is keyed by spelling and two modules cannot collide. The C backend names an error
`nul_error_<name>_<index>` for the same reason. What this buys, in one line:

```
error[E0201]: nothing named 'NotFund' is in scope here
  = help: did you mean 'NotFound'?
```

### Every `!` carries its set

A function states what it can fail with. The compiler verifies the statement and never
infers one.

```nul
pub error FileError = NotFound | PermissionDenied

pub fn read_file(arena: Arena, path: str) FileError![]u8
pub fn save(path: str) FileError!                        // fails, or nothing
fn find(id: i64) ?*User                                  // may be absent
fn lookup(id: i64) FileError!?*User                       // may fail, may be absent
```

This is the same choice the language already made for memory. From `memory.md`: inferring
the cleanup point is a whole program property, while verifying a stated one is local and
decidable. Errors are that shape exactly. A function's set is checked against the sets of
what it calls, which are in their signatures, plus its own returns, which are in its body.
Nothing crosses a module boundary, and nothing depends on a body the reader cannot see.
Inferring for errors while refusing to infer for memory would leave the language holding two
philosophies about what a signature means.

There is no universal set and no open `!T`. An escape hatch would become the one thing
everyone writes, and then the sets would be ceremony without safety.

**Sets widen on their own, in one direction.** `FileError` flows into `ConfigError` with
nothing written at the call site, and never the reverse. That is what lets the middle of a
call stack propagate without conversion machinery, and it is why aliases defined by
reference stay current:

```nul
pub error ConfigError = FileError | BadSyntax   // gains whatever FileError gains
```

**The compiler never leaves you guessing.** It can compute the required set from local
information, so when the stated one is wrong it says what to write:

```
error[E02xx]: 'load' can also fail with 'BadSyntax'
  = help: write '(FileError | BadSyntax)!Config', or name the set
```

It computes it and refuses to publish it, which is the whole point.

**The cost, stated plainly.** Adding an error to a published function is a breaking change
for everyone who propagates it. That is true of the API whether or not the compiler says so,
and this design says so.

### No payloads, permanently

`error Missing { path: str }` has to put that `str` somewhere, and everything lives in an
arena. `try` then carries it up through functions whose scratch arenas die on the way out.
The region checker would have to prove the payload outlives every frame it crosses, which
means `!T` carries a region, which means every fallible signature carries a lifetime. That
is the annotation budget the language spends nothing of.

What programmers write instead: declare the error that matters, since `line: 42` is data and
"the syntax was bad" is identity; return the detail in the value; or take an out-parameter
for the report, which is the arena-native answer because the caller owns the memory the
detail lands in.

```nul
fn parse(arena: Arena, text: str, report: *var Report) ParseError!Config
```

### `orelse` stays

Folding `orelse` into `else` was tried and reverted. It costs one keyword and buys a word
doing two jobs, which `AGENTS.md` names directly: do not overload a name with multiple
context-dependent meanings.

It also contradicts the reason `catch` is a separate word. Failure and absence deserve
different words so a reader always knows which kind of thing is in hand, and by that same
argument absence deserves a different word from "the condition was false". Three ideas, three
words:

- `if` and `else`, the condition was false
- `orelse`, the value was absent
- `catch`, the call failed

The grammar was not the problem. `if` takes its own `else` greedily, so the merged form
parsed unambiguously and every case was pinned by a test. The tell was that the test had to
exist at all: `if opt else flag { }` is legal, deterministic, and still makes a reader stop
and re-parse, and a test file whose job is to prove a keyword is not confusing is the keyword
telling you it is.

The role split survives into `match`, whose catch-all arm is `else`, because that is the same
"remaining arm of a branching construct" job `if` already gives the word.

### `_ =` stops silencing failures

`_ = risky(seed)` compiles today and drops the error. The escape hatch already exists and
already looks as suspicious as it is: `risky(seed) catch {}`. `_ =` keeps working for
values, including one a `catch` already produced.

## Part two: expressions and statements

**Rule 1. `if` is an expression.** With an `else`, its value is what its arms agree on.
Without one, its value is nothing, so it can only be used as a statement. It looks identical
in both positions, which is why the arms are braced: braceless arms would make the two forms
look different, and `if c -1 else 0` is a line the parser resolves greedily and a human
cannot resolve at all.

**Rule 2. A block in value position is worth its final expression.** In statement position
a final expression that has a value is still refused, with the message that exists today.

```nul
let port = read_port() catch |e| {
    log(e)
    8080
}
```

Rust needs `;` to separate "this is the value" from "this is a statement", and that is the
single most confusing thing about Rust blocks. We do not need it, because discarding is
spelled `_ =`. A trailing expression with a value is an error today, so no program changes
meaning.

**Value position is exactly three places**: an `if` arm when the `if` is used as a value,
the right of `catch` or `else`, and a `match` arm when `match` arrives. **A function body is
not one of them.** `return` stays explicit, `missing_return` keeps its diagnostic, and the
single-expression form already exists and composes:

```nul
fn max(a: i64, b: i64) i64 = if a > b { a } else { b }
```

Implicit return from a block body would be a second way to write that line.

**Rule 3. `return`, `break`, and `continue` are expressions that never produce a value.**
One rule instead of three special cases:

```nul
let user = find(id) else return
let cfg = load(path) catch return
let n = if c { count() } else { break }
```

**Rule 4. `while` is not an expression.** It has no natural value, and giving it one means
`break value` and labels.

### Grammar notes

- A block is an expression only where the grammar already places one. No bare block
  expressions, so `{` at the start of a statement stays illegal.
- Dangling `else` binds to the nearest `if`. Applying the optional `else` to an
  if-expression needs parentheses, which is fine, because it is nonsense without them.
- `else` stays on the same line as the `}` that closes its `if`. The rule and its diagnostic
  already exist.
- Nul has no `T{ }` literal, only `.{ }` with a type from context, so a `{` after a
  condition is never ambiguous. Rust needs a parsing restriction for this. We get it by
  construction and should keep it.

### What this deletes

A rewrite of the messiest corner of `Check.zig`, not an addition to it. `checkRescue`'s two
paths and the liveness bookkeeping that decides whether the fallback handed a value back or
fell through collapse into one path. `checkOrelse`'s separate constant-null branch goes.
`checkScopedBlock` and `checkBlockBody` become one `checkBlockValue`. `checkIf` becomes one
function taking a type hint, and the statement form is the call that passes none.

Statement position is spelled as a hint of `nothing_type`, which is not a trick: it is
already the type of what a statement produces. That one value is what tells an `if` to keep
its arms and drop its value.

### Handling a failure is not acknowledging a value

`catch` and `orelse` settle one path. They say nothing about the value on the other one, and
the language's rule is that **every produced value is bound, returned, or explicitly
discarded**. So a `catch` in statement position whose payload is not nothing is refused:

```nul
risky() catch {}         // refused when 'risky' returns '!i64'
_ = risky() catch 0      // two drops, two marks
save() catch {}          // clean, because 'FileError!' has no payload to drop
```

Without this, `quiet()` would be refused for throwing away an `i64` while
`risky() catch {}` threw one away silently, which is the same mistake wearing a `catch`.
Keeping the invariant whole also keeps the one hook a must-use rule would ever need: there is
no path by which a value reaches nobody without saying so.

The friction lands where it should. A function called for its effect returns `E!`, and
`catch {}` on that is clean. A function called for a value you then ignore is rare, and being
made to write it down is the point.

Two consequences worth writing down.

**An arm has to produce something a slot can be made of.** Three values cannot back storage,
and they are one question rather than three: a bare number, a bare null, and nothing at all.
`typeCanHold` asks it once.

```nul
let n = if c { 10 } else { 100 }              // refused, no type
let n = if c { null } else { null }           // refused, no type
let n = if c { effect() } else { effect() }   // refused, no value
let n: i64 = if c { 10 } else { 100 }         // fine
```

The first is the rule `var x = 5` already follows, and the fix is the same annotation.
Defaulting to `i64` was considered and left alone, because it would be the one place in the
language where something converts on its own. It stays available as a strictly more
permissive change later.

**The guard pattern costs a round trip.** `let v = opt orelse { return 0 }` used to lower
without a slot, because the old code checked the fallback first and noticed it left. The
uniform lowering stores and loads instead. The trade is deliberate: a C compiler removes that
store and load in its first pass, and keeping a special case in the checker to save an
instruction the backend deletes is the wrong direction.

**A slot is typed after its arms are read.** An `if` in value position needs its slot before
the branch, which is before either arm has said what type it is, so the slot is emitted
untyped and named once at the join. That is the only instruction the builder rewrites, and
it is asserted to be a `local`.

## Part three: enums

Nul gets sum types, and the plain enum is the case where the payload is zero bytes. One
declaration form, one layout rule, one way to read a payload.

```nul
enum Color { Red  Green  Blue }

enum Shape {
    Circle { radius: f64 }
    Rect { width: f64  height: f64 }
    Point
}
```

**Two shapes, not three.** A bare name when there is no payload, braces when there is. The
single-payload form `Int: i64` is rejected even though it is terser, because it leaves the
payload unnamed, and then every match site invents its own name for it. The braced form
names it once at the declaration and every site binds it by that name. Less total naming,
and consistent naming. It is also the field syntax that structs already use.

**Reading a payload requires `match`.** Field access on an enum is a compile error
everywhere else, with no exceptions:

```nul
match s {
    Circle { radius } => area(radius)
    Rect { width  height } => width * height
    Point => 0.0
}
```

**There is no `is`, and no narrowing.** `==` compares values, which covers every error and
every payload-less variant. A payloaded variant has nothing to compare against, so the
question is not which keyword but which construct, and the answer is `match`.

That is not only one fewer keyword. `is` would need flow-sensitive type refinement in the
checker, so that `s.radius` becomes legal inside one branch and not another, and that
refinement has to survive assignment, loops, and captures. `match` needs none of it, because
each arm binds fresh names at a known variant. Refusing `is` deletes a whole class of
machinery before it is written.

**Errors are not enums**, and the reason is precise: errors widen on their own and enums
must never. `try` carries an error across many boundaries with no conversion written
anywhere, which only works if a smaller set silently becomes a larger one. Silent widening
between enums would destroy exhaustiveness and type identity, which are the two things enums
exist for. Rust needs the entire `From` trait and its blanket impls because it made errors
ordinary enums and had to bolt widening back on afterwards.

Open inside this part, to settle when the work starts: the layout and niche packing rules,
whether a payload-less variant is also a value that can be assigned directly, and whether
`match` gets a wildcard arm or only exhaustive covers.

## Part four: the rest of the audit

**Refuse `while true` and `while false`.** Today they disagree with `while { }`:

```nul
fn a() i64 { while true { return 1 } }   // error: a path falls off the end
fn b() i64 { while { return 2 } }        // fine
```

The condition is a compile time `true` and the checker does not notice. Refusing both, with
help pointing at `while { }`, gives one way to write an infinite loop and deletes the
inconsistency at the same time.

**Refuse `?!T`.** `!?T` means "may fail, and may succeed with nothing", which is real. `?!T`
is an optional holding a failure, which is nonsense ordering. `!!T` is already refused with
"one '!' is enough"; this is the same rule with the other ordering.

Both refusals read the resolved type rather than the written node, so an alias cannot smuggle
a second `!` past them. And the refusal names `!?T` as the shape that is meant, which turned
out to require fixing it: `coerce` wrapped a runtime value exactly one level, so `return id`
into `!?i64` was refused even though the same line worked for a constant, which reaches it
through `meetOrWrap`. `coerceQuiet` now wraps one level per level of the wanted type, which
is what `meetOrWrap` always did, so the two paths finally agree.

**A comma separates items, and so does a newline.** Today a struct body accepts only
newlines, so `struct Nice { a: u8  b: u32 }` does not parse and there is no way to write a
small type on one line. The rule becomes one sentence and applies to every braced list of
items:

> Items are separated by one or more separators. A newline is a separator, and so is a
> comma.

```nul
struct Nice { a: u8, b: u32 }
struct Point {
    x: i64
    y: i64
}

enum Color { Red, Green, Blue }
enum Shape {
    Circle { radius: f64 }
    Rect { width: f64, height: f64 }
    Point
}

match x { A => 1, else => 0 }
```

This is not a new idea in the language, it is the existing one stated once instead of twice.
Parameters, call arguments, and struct literals already read commas, and declarations already
read newlines. The two were never a choice between spellings, they were the same rule split
across two places in the parser.

Scope: field-like lists only, which is struct fields, enum variants, and match arms.
Statements stay newline separated, because a comma between statements reads like C's comma
operator and means something else everywhere it appears in this language.

**Kept, deliberately.** `fn f() T = expr` beside `fn f() T { return expr }`, because the `=`
form is how every primitive binds and there it says something a block cannot. And
`counter.total()` beside `Counter.total(counter)`, because constructors need the static form
and removing the overlap would mean a rule with an exception.

**Clean already, and worth protecting.** One struct literal form and no field defaults, one
discard form, one pointer spelling, one import form, one visibility marker, and no
shadowing.

## Part five: how a step is finished

No step is done when it compiles. A step is done when the tests say so, and the tests are
written as part of the step rather than after it.

Every step lands with cases under `test/`, in the directory that matches what is being
proven:

| directory | proves |
|---|---|
| `test/parse-pass` | the new syntax parses, and the tree is what it should be |
| `test/parse-error` | the syntax that should not parse does not, with the right message |
| `test/pass` | the program checks clean, and the IR is what it should be |
| `test/fail` | the program is refused, with the exact diagnostic |
| `test/multi` | it still works across module boundaries |
| `test/emit` | the C is what it should be |
| `test/run` | the program runs and leaves the right exit code |

Rules for the cases themselves:

- **Both spaces.** Every rule gets a case that satisfies it and a case that violates it. The
  boundary between valid and invalid is where the bugs are, so a rule with only passing
  cases is untested.
- **Edge cases named, not sampled.** Empty, one, many. The first item and the last. Nested
  to the depth limit and one past it. The interaction with `defer`, with a loop, with an
  early `return`, with a poisoned type. Where a limit exists, test at the limit, one below,
  and one above.
- **Expectations are read, not regenerated.** `zig build test-update` rewrites what the
  tests expect, which makes it trivial to bless a wrong answer. Every regenerated expectation
  is read line by line before it is committed, and a diagnostic's text is checked for being
  the message a person would want, not merely for being stable.
- **Rewritten, not amended.** When a step replaces a construct, the old construct's tests are
  deleted, not edited around. A test file mentioning a form the language no longer has is the
  same debt as compiler code for it.
- **The whole suite passes before the next step starts.** `zig build test` green, with no
  known failures carried forward and nothing skipped.
- **Every diagnostic the compiler can emit has a case.** The check is mechanical: the set of
  codes reachable in `compiler/` minus the set appearing in `test/**/*.expected` is empty. A
  code with no test is a message nobody has read.
- **A cascade is a bug in the grammar, not a property of the test.** When one mistake
  produces a page of errors, the production that owns the construct gave up instead of
  recovering. Fix the production.
- **A step that adds a new shape of value is not done until a machine has looked for the
  consumers that do not know about it.** Hand written cases cover what the author thought of,
  which is the one thing that cannot find what the author forgot. Adding `.never` left three
  consumers assuming a value always arrives, and a generated corpus found seventy programs
  that reached them in about a minute.

Two things do that looking, and both are in the build.

**`test/fuzz.zig`** splices fragments into random programs and asks one question:

> For any input, the compiler reports diagnostics or produces working output, and never
> panics.

It knows nothing about what any construct means, which is exactly why it finds the
interactions nobody predicted. A short run rides on every `zig build test`, and
`zig build fuzz -- --iterations 50000 --seed 7` is the long one. A failure is a panic, so
the run stops where it broke, and `--trace` names the program to reproduce.

**`compiler/Verify.zig`** says out loud what a finished body must be true of, at the seam
where the checker hands it over: every surviving block ends, every operand names an
instruction that exists, every terminator names a block that exists, a `scope_end` names a
`scope_begin`, and in a program that reported nothing, every type is a type all the way down.
That last one is not the same as `isType`. `*var poison` passes `isType` and panics the
backend two stages later, which is how it was found.

The value of a verifier is that it fires. This one was tested by putting the bug back: with
the guard removed, the failure lands on `Verify.zig` naming the body, instead of inside
`EmitC` naming nothing.

## Part six: order of work

1. `_ =` refuses an error union. `while true` and `while false` refused. `?!T` refused.
2. Expressions and statements, the four rules, including the deletion of the `catch` and
   `orelse` special cases.
3. Declared errors.
4. Mandatory sets. This removes the universal error type from the pool, makes `!` infix
   everywhere, and adds subset coercion. The backend does not change, because an error is
   still one integer.
5. Enums and `match`.

The separator rule rides along with whichever step first touches the parser.

One and two are small and independent. Three and four are one piece of work in two steps.
Five is its own project and should not start until four is finished, because the widening
rule is what keeps the two mechanisms apart.

## Part seven: still open

Not part of this work. Each changes what the language is.

**Strings and slices do not exist.** `str` and `[]Item` appear throughout `memory.md` and
are not in the language. Both are a pointer and a length, both carry a region, and both need
a bounds story. This is the next real feature after the region checker, and it will be the
first serious test of that checker's design.

**`for`.** `memory.md` writes `for item in items`. It needs slices first.

**Arithmetic is not safe.** Constants fold in 128 bits and overflow is a compile error, but
a runtime `a + b` emits plain C and wraps or invokes undefined behaviour. The README says
memory safe, and that is still true, but a reader will hear more. Trap, wrap explicitly, or
say plainly that arithmetic is C's.

**Uninitialized memory.** `arena.create[T]()` hands back uninitialized memory and nothing
checks that a field is written before it is read. Two answers. Zero the allocation, which
costs one clear, is often free on pages the operating system already zeroed, makes every
`?*T` start null and every struct start valid, and deletes an analysis before it is written.
Or a definite initialization pass over the IR, which is the region checker's dataflow shape
again. The first is more in the spirit of the language, which spends a little runtime to buy
the absence of a rule.

**A formatter.** For a language whose pitch is that it is relaxing, `nul fmt` with no options
is the highest return per line of code available in this project. It also freezes the
newline rules, the `} else {` line, and the one-field-per-line style so nobody has the
argument twice.

**Tests.** There is no way to write one. `test "name" { }` as a declaration kind is the
shape, and it costs almost nothing given the declaration machinery that exists.
