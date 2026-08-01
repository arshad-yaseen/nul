# The Region Checker

`memory.md` states the model. This states the machine that proves it.

The checker is a pass over the typed IR, one function at a time, that answers exactly two
questions and refuses to guess at either:

1. Does every store put memory into memory that dies first?
2. Does anything touch memory whose arena has already gone?

Everything below is how those two questions become table lookups.

## Design axioms

These are load bearing. Each one removes a class of imprecision or a class of unsoundness,
and every later decision is downstream of them.

**A1. The IR is the subject, not the syntax.** Every fact the checker uses is an
instruction, an operand, or a type. Nothing is re-derived from the tree, and nothing is
guessed from a name. The lowering already normalised control flow into blocks, put every
scope exit on every path, and gave every value a type, so the pass reads a graph rather
than re-interpreting a program.

**A2. A contract is a function of a signature.** What a call promises and what it demands
are computed from the callee's parameter types and return type alone. No body is ever
consulted, no summary is inferred, and no fixpoint runs across the call graph. This is
what keeps the check local, keeps it working across module boundaries, keeps recursion
free, and keeps an error explainable by pointing at one signature.

**A3. Every judgement is reachability in a graph the function builds for itself.** There is
one relation, `outlives`, one query, and no special cases. Rules that look different in
`memory.md` are the same query with different endpoints.

**A4. A value carries a set, not a guess.** Where a value could point into one of several
regions, it carries all of them, and a check must hold for all of them. Joining never
invents a region and never loses one.

**A5. Unproven is refused.** There is no default direction, no "probably fine", and no
heuristic. If the graph has no path, the store is rejected and the message names both ends.

**A6. Poison is silent.** A value the type checker already reported on carries the region
that satisfies everything, so one mistake produces one message.

## Part one: the region graph

### Nodes

A **region** is a lifetime. Per function body the checker builds a small directed graph of
them, one node per site in the IR that can name a lifetime.

| node | one per | means |
|---|---|---|
| `forever` | the function | outlives everything. What a number carries. |
| `param(p)` | pointer, arena, or pointer-holding parameter | the memory that parameter reaches, named from outside. |
| `call` | the function | the duration of this call. |
| `scope(s)` | `scope_begin` | the storage of the locals declared in that scope. |
| `arena(i)` | `arena_init` or `arena_child` | the memory that arena hands out. |
| `result` | the function | the lower bound a caller is entitled to assume of the result. |

That is the whole vocabulary. Nothing is created by a join, by a load, or by a call, so the
node count is fixed by the shape of the body before the dataflow starts, and one counting
pass sizes every bitset the pass will ever need.

### Edges

An edge `A -> B` reads **A outlives B**. Every edge is placed at the instruction that makes
it true.

| where | edge | why |
|---|---|---|
| entry, each parameter `p` | `param(p) -> call` | a parameter is borrowed from the caller, so it cannot die during the call. |
| entry, each `*var T` parameter `p`, when the function also takes an arena `a` | `param(a) -> param(p)` | the caller proved it. This is the one rule the model states and the caller checks. |
| entry | `call -> scope(0)` | the body's outermost scope ends inside the call. |
| `scope_begin` in scope `P` | `scope(P) -> scope(S)` | an enclosing scope outlives an enclosed one. |
| `arena_init` in scope `S` | `scope(parent of S) -> arena(i)`, `arena(i) -> scope(S)` | a root arena dies where it was declared. |
| `arena_child(a)` in scope `S` | `c -> arena(i)` for each `c` the operand carries, and `arena(i) -> scope(S)` | a child draws from its parent and dies at its own scope. |
| entry | `param(p) -> result` for each incoming region parameter, or `result` **is** `param(a)` when there is an arena parameter | the result contract, below. |
| entry | `result -> call` | the caller keeps the result. |

Two things are deliberately absent. There is no edge between two parameters, because
nothing proved one outlives the other. There is no edge from a scope to an arena declared
in it, because two arenas declared in one scope are siblings and neither outlives the
other. That absence is the entire sibling rule, and it costs zero code.

### The query

Every rule in this document is one call:

```
outlives(A, B)  ==  B is reachable from A
```

Nodes are created in topological order. A scope is opened inside its parent, a child arena
after its parent, a parameter before everything. So the transitive closure is maintained
**incrementally at creation**, in one row update per node, with no iteration:

```
down[k] = {k} | union of down[p] for each parent p of k
for each existing r:  down[r][k] = or over parents p of (down[r][p])
```

`down[r]` is the set of nodes `r` outlives. The query is one bit test. The closure is a
bitmatrix of `n` rows by `n` bits, `n` being the node count found by the counting pass, so
a typical function spends a few hundred bytes and a large one a few kilobytes.

One extra relation rides along, computed the same way: `descendants(a)`, the arenas reached
from `a` by `arena_child` edges only. `reset` and `destroy` need it, and it is a strict
subset of `outlives`, so it cannot be conflated with it.

## Part two: what a value carries

Each value in the IR carries a **candidate set**, the regions its memory may live in. Its
meaning is exactly the model's invariant:

> Everything reachable from this value outlives every region in the set.

A set rather than a node, because a branch can leave a value pointing into either of two
regions, and one node cannot say that without lying in one direction. Joining two values is
set union, which is monotone, cannot invent a region, and terminates.

The set is a bitset over the same `n` nodes as the closure, so a check is bitwise.

Values whose type reaches no pointer and no arena carry `{forever}` and are skipped
entirely. The gate is one predicate:

```
holdsPointer(T)
    pointer                    -> true
    struct with is_region      -> true          an arena you can name is memory you can reach
    struct                     -> any field holds
    optional, error union      -> child holds
    everything else            -> false
```

Memoized per pool index. It terminates because a pointer stops the walk, and a struct that
embeds itself by value has already been refused by the size check. This one predicate
serves three purposes: it prunes the dataflow, it is the rule `copy` is refused by, and it
decides which parameters are incoming region parameters.

### Transfer functions

The pass is total over `Inst.Tag`. Nothing is left to a default arm.

| instruction | candidate set of the result | other effect |
|---|---|---|
| `param` | `{param(p)}` for a region-carrying parameter, else `{forever}` | |
| `local` | `{scope(current)}`, the slot's own storage | opens a tracked path |
| `load(place)` | the tracked set when `place` is a tracked path, otherwise the candidates of `place` | the fallback **is** the invariant. What sits in memory of region R outlives R. |
| `store(place, value)` | nothing | **the store check**, then a strong or weak update of the tracked path |
| `field_ptr(base, row)` | candidates of `base` | extends the tracked path when `base` is one |
| `field_val(base, row)` | the recorded field set when `base` is a `struct_init` the pass saw, else candidates of `base` | |
| `struct_init` | union of the field operands | records the per-field sets for `field_val` |
| `call` | the result contract, below | the call obligations, and invalidation of every tracked path whose address was passed |
| `arena_init` | `{arena(i)}` | new node |
| `arena_child(a)` | `{arena(i)}` | new node, parents are the candidates of `a` |
| `arena_create(a)` | candidates of `a` | |
| `arena_copy(a, v)` | candidates of `a` | **the copy check** on the result type |
| `arena_reset(a)`, `arena_destroy(a)` | nothing | **the release**, below |
| `wrap_optional`, `unwrap_value`, `wrap_ok`, `unwrap_ok` | candidates of the operand | an optional or an error union is a box, not a region |
| `wrap_err`, `unwrap_err` | `{forever}` | an error value is a number |
| `has_value`, `is_error`, `not`, every compare | `{forever}` | |
| `add` through `mod`, `negate` | `{forever}` | |
| `scope_begin` | nothing | pushes a scope node |
| `scope_end` | nothing | pops it, kills what died with it |

Note the shape of the `load` row. It is the only place the invariant is *used* rather than
maintained, and it is why no region ever needs to appear in a type. Reading a pointer out of
memory in region R yields a pointer known to outlive R, which is precisely what the model
promises and precisely what a caller of `push` is entitled to.

## Part three: the four checks

### 1. The store

At `store(place, value)`, with `D` the candidates of the place and `S` the candidates of the
value:

```
for every s in S, for every d in D:  outlives(s, d)
```

Every row of the model's direction table is this one loop:

| storing | into | the loop asks | answer |
|---|---|---|---|
| `arena` memory | `arena` memory | `outlives(P, P)` | reflexive, passes |
| `arena` memory | `scratch` memory | `outlives(P, S)` where `P -> S` | passes |
| `scratch` memory | `arena` memory | `outlives(S, P)` | no path, refused |
| sibling child | sibling child | `outlives(S1, S2)` | no path, refused |
| `arena` memory | a `*var` parameter | `outlives(P, param(p))`, the caller's edge | passes |
| `scratch` memory | a `*var` parameter | `outlives(S, param(p))` | no path, refused |

Six rows, one loop, no case analysis. An arena value stored into memory is the same loop,
because an arena value carries the region it denotes rather than the region its handle sits
in, and the parent always outlives the handle.

### 2. The return

At a `ret v` where the return type holds a pointer:

```
for every s in candidates(v):  outlives(s, result)
```

`result` is the node defined at entry. Which node it is *is* the language's result contract,
and it is worth stating on its own:

> **A function that takes an arena returns memory in that arena. A function that does not
> returns memory that outlives the pointers it was given.**

Mechanically:

- with an arena parameter `a`, `result` is `param(a)`, so returning anything but
  `a`-derived memory is refused;
- without one, `result` is a node under every incoming region parameter, so returning
  anything reached through any parameter passes;
- with neither, `result` has nothing above it but `forever`, so only a pointer free value
  can be returned, which is the only thing such a function can build anyway.

The second case is what makes `push` work with no annotation. `self.arena` loads as
`{param(self)}`, allocation from it stays `{param(self)}`, and `param(self) -> result` is an
entry edge. The check passes without the callee knowing which arena it allocated from, which
is the whole point of the model.

The first case has a consequence to state plainly rather than hide. A function that takes an
arena **and** returns something reached through one of its pointer parameters is refused,
because nothing proved that parameter outlives the arena. The refusal is correct, the fix is
mechanical, and the message says it:

```
error[E0251]: 'find' allocates from 'arena', so its result lives there
 --> find.nul:6:5
  |
6 |     return tree.root
  |            ^^^^^^^^^ this points into memory reached through 'tree'
  |
  = help: nothing here proves 'tree' outlives 'arena'; drop the arena parameter if this
          function only borrows, or copy what it returns into 'arena'
```

The alternative, making the result the meet of the arena and every pointer parameter, was
considered and rejected. It moves the refusal to the caller and breaks the central idiom of
the whole model, where a scratch buffer is read and a long lived result is built:

```nul
let text = try io.read_file(scratch, path)
let tree = try parse(arena, text)          // must stay `arena`, not `scratch`
```

Refusing a rare callee is cheap. Refusing that call is not.

### 3. The call

At a `call` with an arena argument `a` and a `*var T` argument `p`, the caller discharges the
obligation the callee assumed:

```
for every s in candidates(a), for every d in candidates(p):  outlives(s, d)
```

The same loop as a store, because it is the same fact: the callee may put `a` memory into
`p` memory, so the store rule applies once here rather than at every store inside.

Two more things happen at a call, both required for soundness:

- the result takes the contract above, read off the callee's signature rows;
- every tracked path whose address was passed is invalidated, because the callee may have
  written through it. Invalidated means the path's set becomes the set of its own place, the
  only bound the callee's own store check guarantees.

### 4. The copy

At `arena_copy` with result type `T`:

```
holdsPointer(T)  ->  refused
```

This is the one primitive with a rule of its own, and the reason is the invariant rather
than an implementation limit. A copy relabels a value as living somewhere new without
touching what its pointers reach, so a copied pointer would make its own tag a lie, and every
later check would be reading a tag that lies. Refusing at the copy is refusing the only
operation that can break the invariant, so the invariant holds everywhere else by
construction.

## Part four: release, and what falls out of it

`reset` and `destroy` are the only moments memory actually goes away, and the ordering rules
say nothing about them. They need a second, flow sensitive fact.

Every tracked value and every tracked path carries one bit beside its set: **may be dead**.

- `arena_reset(a)` sets the bit on every value whose set meets `descendants(c)` for any `c`
  the operand carries. The arena itself stays usable, which is what makes the scratch loop
  work.
- `arena_destroy(a)` does the same, and additionally marks those arena nodes destroyed.
- `scope_end(s)` does the same for the arenas declared in `s` and the slots of `s`.
- a merge joins the bit with `or`, so a value dead on any path is dead.

A **use** is any occurrence of a value as an instruction operand or as a terminator operand.
A use of a value with the bit set is refused. Loads, field addresses, calls, stores, and
returns are all uses; re-assigning the slot that held it is not, because the store's operand
is the new value.

Three separate rules from `memory.md` fall out of that one bit without any code of their own:

**Use after reset.** The model's example is exactly the dataflow:

```nul
    var item = scratch.create[Item]()
    item.weight = 42
    scratch.reset()                  // item's bit is set here
    return item.weight               // field_ptr uses a dead value
```

**A `destroy` inside a loop.** The model wants this refused when the arena was made outside
the loop. No loop analysis is needed. The bit and the destroyed mark travel around the back
edge, so on the second visit the destroy is standing on an arena that may already be
destroyed, and the pass says so. The same machinery catches a double destroy on a straight
line, and catches allocating from a destroyed arena, neither of which needed a rule.

**A `defer` that outlives its value.** The lowering already re-emits a defer on every exit
path, before the return, and the IR shows it:

```
  %7  = wrap_ok 1:i64
  %9  = load %4
  %10 = arena_reset %9      // the deferred reset, on the way out
  return %7
```

If the returned value had lived in that arena, its bit is set by `%10` and the `return` is a
use of a dead value. A whole bug class, caught because the pass reads the IR the compiler
actually built rather than the source the programmer wrote.

## Part five: local slots

The store check alone is sound but blunt. If `load` of a local always returned the slot's own
region, `var a = arena.create[Node](); return a` would be refused, and that is the first line
of every arena program. So local storage is tracked exactly.

A **tracked path** is a `local` instruction followed by zero or more `field_ptr` steps and
nothing else. The moment a `load` intervenes, the path has crossed a pointer into the heap
and tracking stops. Paths are interned per function into a small table, up to
`path_depth_max` steps deep, and a store deeper than that weakens the deepest tracked prefix
instead of replacing it.

- a store to a tracked path **replaces** its set, a strong update;
- a store to an untracked place, or past the depth cap, **unions** into the nearest tracked
  prefix, a weak update;
- a call passing the address of a tracked path invalidates it.

Strong update is the aggressive move, so its soundness needs an argument rather than an
assertion. It rests on a lemma the language already enforces for another reason:

> **A frame address can never be stored.** `&` is legal only as a call argument, so the only
> way one could escape is if a callee stored it. A callee storing a parameter `p` into
> memory of region D must prove `outlives(param(p), D)`, and the caller passed a frame
> address, whose region dies with the call. The callee has no D that survives it.

So a local slot has no aliases the pass has not already accounted for, and replacing its set
is exact. `E0223`, which reads today like a syntactic restriction on `&`, is in fact the
premise of the checker's precision.

## Part six: the dataflow

State at a program point is the candidate set and the dead bit for every instruction result
and every tracked path, plus the active scope stack.

- blocks are visited in reverse postorder, on a worklist, until no state changes;
- a merge unions sets and ors dead bits, and **asserts** that the predecessors agree on the
  scope stack, which the structured lowering guarantees and the assertion proves;
- the lattice is finite. Sets only grow, bits only turn on, no node is ever created by a
  merge, so the pass terminates in at most `nodes x paths` visits per block. The bound is
  computed and asserted, not assumed.

Instruction results are dense, so their sets live in one array indexed by instruction. Path
states are dense per function, so they live in one array indexed by interned path. Both
buffers hang off the pass object and are cleared per function rather than allocated per
function, so a whole program costs one growth to the largest body in it.

Bounds, in the house style, chosen so that no program a person writes meets them:

| limit | value | on hitting it |
|---|---|---|
| `regions_max` | 256 nodes per body | one diagnostic naming the function, body skipped |
| `paths_max` | 1024 tracked paths | tracking degrades to weak update, no diagnostic, still sound |
| `path_depth_max` | 3 steps | deeper stores weaken the prefix, no diagnostic, still sound |

Only the first can change an answer, and it reports rather than guesses. The other two
degrade toward refusal, never toward acceptance.

## Part seven: diagnostics

The graph carries what a message needs. Every node keeps its name, the AST node that
created it, and its kind, so both ends of a failure can be pointed at. Codes 237 and 240 are
free, and the rest continue the sequence.

| code | name | fires at |
|---|---|---|
| E0237 | `region_escape` | a store whose value dies first |
| E0240 | `use_after_release` | a use of a value whose arena was reset, destroyed, or left scope |
| E0251 | `result_region` | a return that does not reach the result contract |
| E0252 | `copy_holds_pointer` | `copy` of a type that reaches other memory |
| E0253 | `arena_released` | destroy, reset, or allocation on an arena that may already be gone |
| E0254 | `arena_outlived` | a call whose arena does not outlive a `*var` argument |
| E0255 | `regions_too_complex` | the node bound |

The store message is the model's own sentence, with both ends named and both creation sites
noted:

```
error[E0237]: 'temp' dies before 'box' does
 --> leak.nul:8:5
  |
8 |     box.item = temp
  |     ^^^^^^^^ this memory outlives what is being put into it
  |
  = help: allocate the value from 'arena', or keep the whole structure in 'scratch'
note: 'temp' lives in 'scratch'
 --> leak.nul:4:19
  |
4 |     var scratch = arena.child()
  |                   ^^^^^^^^^^^^^ a child of 'arena', so it dies first
note: 'box' lives in 'arena'
 --> leak.nul:1:9
  |
1 | fn leak(arena: Arena) *Box {
  |         ^^^^^^^^^^^^ the arena this function allocates from
```

Where a value's set has more than one region, the message names the one that failed and says
"may", because the value reached the store on more than one path. That is honest about the
merge without exposing the lattice.

## Part eight: where the pass sits

A new file, `Region.zig`, with one entry point:

```zig
pub fn check(comp: *Compilation, func: *const IR.Func) Allocator.Error!bool
```

called from `Check.fnBody` after `finishFunc`, on a body that already type checked clean. It
reads `comp.instanceRows` and `comp.instanceType` for the callee contracts, which are
resolved before any call was emitted, and it writes only diagnostics.

Everything it needs is already in the IR. The audit, tag by tag, found one thing worth
recording rather than changing: `IR.Callee` reserves a bit for a foreign callee it does not
yet have. When foreign calls arrive they arrive with no signature the checker can read, so
they need a contract of their own before they are allowed to take a pointer. Everything else
is present: `Inst.node` gives every span, `param` and `local` give every name, `scope_begin`
and `scope_end` give the tree, and the six primitives are already distinct tags.

The existing arena rules stay where they are, because they are about syntax rather than
lifetime: one arena per function (E0236), release needs a name (E0238), a redundant deferred
destroy (E0239), and `&` only as an argument (E0223).

## Part nine: known imprecision

Stated here rather than discovered later. Both are refusals, never acceptances.

**One. A local container hides its arena.**

```nul
var list = List.init(arena, .{ cap: 8 })
let top = list.push(2)
return top                              // refused
```

`push` promises its result outlives `self`, and `self` here is a local, so the promise is
"outlives this frame". The entry genuinely lives in `arena`, but no signature says so. This
is the lower bound `memory.md` chose on purpose, and tightening it would need the promise to
read `self.arena` rather than `self`, which is unsound, because `push` may also return
`self.first`, and that only outlives `self`. The workaround is to name the arena at the
boundary the value crosses, which is where a reader wants it named anyway.

**Two. Borrowing and allocating in one signature.** The result contract case above. A
function takes an arena and returns something read out of a pointer parameter. Refused, with
a message that names the fix.

Neither is a soundness hole, and neither is silent.

## Part ten: proving it

**Unit, in `Region.zig`.** The closure against a naive transitive closure over random DAGs,
positive and negative space. Set operations at the word boundary. The bound arithmetic at
`regions_max` exactly, one below, and one above.

**File tests, one per row of the model.** Every row of the direction table, in both
directions, as a `pass` and a `fail`. Siblings. Nested children. A stored arena, through
`init` and through `push`. Reset in a loop. Destroy early, destroy twice, destroy in a loop,
allocate after destroy. A deferred reset that kills a returned value. `copy` of a plain
struct and of a struct holding a pointer. The `*var` obligation, both ways. Pointers inside
optionals and inside error unions.

**The property worth fuzzing.** Generate small bodies at the IR level, run the pass, and
compare against an oracle that enumerates paths and checks stores directly. The pass must
never accept what the oracle refuses. It is allowed to refuse what the oracle accepts, and
the gap between them is the imprecision above, which the fuzzer measures rather than
assumes.

## The checker in one page

- One graph per function, one node per lifetime site, edges placed where they become true.
- One relation, `outlives`, and one query, reachability, maintained incrementally because
  nodes are born in topological order.
- One set per value, joined by union, so a branch is never resolved by guessing.
- Four checks: the store, the return, the call, and the copy. Each is the same loop over two
  candidate sets.
- One bit for liveness, from which use after reset, destroy in a loop, double destroy, and a
  deferred reset that eats the result all fall out with no rules of their own.
- One lemma, that a frame address cannot be stored, which makes exact tracking of local
  storage sound and is already enforced for its own reasons.
- Two known imprecisions, both refusals, both named.
