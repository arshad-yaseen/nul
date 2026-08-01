# The Nul Memory Model

Nul is a systems language with no garbage collector, no runtime, and no cleanup code
you did not ask for. Every program is memory safe, and the compiler proves it before
the program runs. The programmer never writes a lifetime annotation, never learns
ownership or borrowing vocabulary, and never argues with an analysis they cannot see.

This document is the entire model. It is short because the model is small.

## The contract

Memory dies when its arena dies, all at once, and no program can read or write it
afterward.

Everything below is one sentence, explained:

> **Inside an arena there are no rules. Between arenas there is one.**

## Rule one: everything is a value

Assignment and argument passing behave as if the value were copied.

```nul
struct Point {
    x: i64
    y: i64
}

var a: Point = .{ x: 1, y: 2 }
var b = a                         // a copy
b.x = 99

// a.x is still 1
```

Two names cannot disagree about the state of one object, because two names cannot *be*
one object, unless you wrote a pointer:

```nul
var a = arena.create[Point]()     // a is a *var Point
var b = a                         // b is the same pointer
b.x = 99

// a.x is 99, because a and b are the same object
```

The compiler is free to turn a copy into a move or a borrow whenever the difference
cannot be observed, which is where the performance comes from. That optimization is
unobservable rather than hidden: nothing a programmer can measure changes.

This rule is what makes the rest of the model tractable. **The only aliasing in a
program is aliasing the programmer wrote down as a pointer.**

## Rule two: memory comes from arenas

There is no global heap and no implicit allocator. Memory comes from an arena, which is
an object you create, choose the backing storage for, and pass down to anything that
needs to allocate.

```nul
pub fn main() !i64 {
    var arena = Arena.init()

    let tree = try parse(arena, "input.txt")

    io.print("{tree.count} nodes\n")
    return tree.count
}
```

Arenas nest, so an arena can draw from a parent. A function that needs temporary space
makes a child, and the child dies when the function returns:

```nul
fn parse(arena: Arena, path: str) !*Tree {
    var scratch = arena.child()                  // dies at the end of this function

    let text = try io.read_file(scratch, path)   // temporary
    var tree = arena.create[Tree]()              // the result

    // ... fill in tree from text ...

    return tree
}
```

Every allocated value belongs to exactly one arena, and its lifetime is that arena's
lifetime. **Nothing is freed individually.** When an arena dies, everything in it dies at
the same instant, in one bulk operation.

### The parameter is doing two jobs

Look again at the signature:

```nul
fn parse(arena: Arena, path: str) !*Tree
```

`arena` is where the function allocates. It is *also* the name of a lifetime. You wrote
it because you needed somewhere to allocate from; the compiler reads it as the region tag
it needs for checking.

This is why the model costs zero annotations. The information the compiler needs is
information you were already writing for your own reasons.

### One arena per function

The sentence above only works if "the arena" names something. With two arena parameters
it would not, and a caller would have no way to know which one a result lives in. So a
function allocates its results into exactly one arena, and taking a second is rejected:

```nul
fn analyze(long: Arena, short: Arena, input: str) *Report {   // rejected
    var r = long.create[Report]()
    r.lines = 0
    return r
}
```

A function that needs scratch space does not take a second arena. It makes a child, which
dies when the function returns:

```nul
fn analyze(long: Arena, input: str) *Report {
    var short = long.child()
    // ...
}
```

That is the natural shape anyway, and it is worth stating as the rule behind the rule:
**what you take from outside is for what outlives the call, and what you make inside is
for what does not.** Scratch space is an implementation detail. A caller forced to supply
one is being told about memory it will never see, and being asked to decide something it
cannot know.

The rule is about arenas, not about pointers. Take as many pointer parameters as you
like, because a pointer carries the region it came from, and a `*var` one says so in the
signature:

```nul
fn record(out: *var List[Entry], arena: Arena, e: Entry)
```

Only allocation needs an arena, and results come from exactly one of them. That single
restriction is what buys every signature in the language the property of saying where its
result lives, while saying nothing at all.

## Rule three: pointers are free inside an arena, checked across arenas

Inside one arena, pointers behave exactly as they do in C. Store them in structs, return
them, hold them in collections, build linked lists, trees, graphs, and intrusive
structures. No restrictions, no overhead, cycles included:

```nul
struct Node {
    value: i64
    next: *Node
    parent: *Node
}

fn link(arena: Arena) *Node {
    var a = arena.create[Node]()
    var b = arena.create[Node]()

    a.next = b
    b.parent = a                  // a and b point at each other, and that is fine

    return a
}
```

This is safe by construction rather than by analysis. Everything in one arena dies at one
moment, so a pointer and the thing it points to cannot outlive each other. There is no
ordering to get wrong.

### The one thing the compiler rejects

A pointer that crosses arenas: memory from one arena stored inside something belonging to
another, or returned to a scope that does not own the arena it lives in.

```nul
fn leak(arena: Arena) *Box {
    var scratch = arena.child()

    var box = arena.create[Box]()
    var temp = scratch.create[i64]()

    box.item = temp               // rejected: 'temp' dies before 'box' does

    return box
}
```

This is the only situation in which memory can die while a pointer to it survives, so it
is the only situation the checker polices.

### Which direction is allowed

Only one of the two directions can dangle, and only that one is rejected:

| storing | into | verdict |
|---|---|---|
| `arena` memory | `arena` memory | free, same lifetime |
| `arena` memory | `scratch` memory | free, the parent outlives the child |
| `scratch` memory | `arena` memory | **rejected**, the child dies first |
| sibling child | sibling child | **rejected**, neither outlives the other |
| `arena` memory | a `*var` parameter | free, the caller proved the parameter outlives `arena` |
| `scratch` memory | a `*var` parameter | **rejected**, that parameter outlives `arena`, and `scratch` does not |

The second row is worth noticing. Long lived memory may be stored inside short lived
memory, always:

```nul
fn stash(arena: Arena) {
    var scratch = arena.child()

    var holder = scratch.create[Ref]()
    holder.target = arena.create[i64]()   // fine, 'arena' outlives 'scratch'
}
```

### What the rule maintains

That table is not four cases. It is one invariant:

> **Every pointer reachable from a value in some arena points into an arena that
> outlives it.**

Storing preserves it: putting a value from `A` into memory in `B` requires `A` to outlive
`B`, so `B` now holds a pointer into something that outlives it, and anything reachable
through that value already outlived `A`. Allocation preserves it trivially, because new
memory holds no pointers yet. Returning is storing into the caller.

That is why a value carries one arena rather than one per field: its tag is a lower bound
on everything inside it. No region ever appears in a type, `*Node` is `*Node` wherever it
lives, and nothing in the language has to be generic over arenas.

### An arena can be stored, and then it is already the right one

An `Arena` is a value, so it can be put in a struct like anything else, and the store rule
applies to it unchanged. Putting arena `A` into memory that lives in `B` requires `A` to
outlive `B`, exactly as it would for a pointer, and for the same reason: an arena you can
still name is memory you can still reach.

That one line has a consequence worth stating on its own, because it removes what would
otherwise be this model's most common annoyance. A container that keeps the arena it was
built from does not have to be handed one again:

```nul
var list = List[Node].init(arena, .{ cap: 8 })
```

```nul
fn push(self: *var List[Node], value: i64) *Node {
    var n = self.arena.create[Node]()
    n.value = value
    // ... put n in the buffer ...
    return n
}
```

`push` takes no arena and asks nothing of its caller. Read the invariant again to see why
it is safe anyway:

> Every pointer reachable from a value in some arena points into an arena that outlives
> it.

`self.arena` is reachable from `self`, so `self.arena` outlives `self`. Allocating from it
and storing the result back into `self` is therefore a store into memory the source
already outlives, which is the direction that is always allowed. **Nothing is checked here
because nothing can go wrong here.**

The obligation did not disappear. It moved to `init`, where the arena is stored into the
list, and that is one ordinary store in a function that has both names in scope.

The result of `push` lives in `self.arena`, which its caller may have no name for. It does
not need one. `self.arena` outlives `self`, so the caller may treat the result as living
at least as long as `self` itself, and that lower bound is enough for every check the
caller will make.

### Copying between arenas

`copy` is the one operation that can break the invariant, because it relabels a value as
living somewhere new without touching what its pointers reach. It copies the bytes a value
directly owns: for a number that is the number, and a pointer does not own what it points
at.

Copying downward, into a shorter lived arena, is harmless, because the inner pointers
already outlived the source, so they outlive the destination too. Copying upward is the
useful direction and the dangerous one. So the rule that keeps the invariant true is a
rule about types, and a type that holds a pointer cannot be copied at all:

```nul
struct Pair {
    left: *Inner
    count: i64
}

fn keep(arena: Arena, p: Pair) Pair {
    return arena.copy(p)          // rejected, 'Pair' holds a pointer
}
```

Copying `Pair` would put a value in `arena` whose `left` points into a shorter lived
region, which is the invariant failing. Every later check would then be reading a tag that
lies, so the compiler refuses at the copy rather than let a laundered pointer exist at all.

Nothing about this is special cased in the language. `copy` is an ordinary library
declaration, and its signature is what every call is checked against. The refusal is the
one rule of the primitive it is bound to, and whether a type holds a pointer is a question
the compiler answers the way it answers any other compile time question. An `Arena` stored
inside a type counts as a pointer here, because an arena you can still name is memory you
can still reach. The region of the result needs no special case either: `copy` takes one
arena, so its result lives in that arena, by the rule already stated.

To move something that does hold pointers, copy what the pointers reach and rebuild around
it:

```nul
var q = arena.create[Pair]()

q.left = arena.create[Inner]()
q.left.value = p.left.value
q.count = p.count
```

### The check is local

Every value carries the arena it came from, and arenas are named by parameters already in
scope, so the check compares two names that both appear in the same function. It never
requires whole program analysis, never crosses module boundaries, and never depends on
what code elsewhere happens to do.

### Reading a parameter is free, writing to one says so

A pointer is `*T` to read through and `*var T` to write through. That is ordinary
mutability, not ownership and not exclusivity, and it is the only part of a signature this
model reads besides the arena.

Reading needs no thought and no arena. A borrowed parameter cannot outlive the call that
created it, so there is nothing to track:

```nul
fn total(c: *Counter) i64 {
    return c.hits                 // no arena, nothing to check
}
```

Writing is where a lifetime question can appear, because the destination belongs to the
caller and this function has no name for the arena it lives in:

```nul
fn bump(c: *var Counter, by: i64) {
    c.hits = c.hits + by          // a number, so still nothing to check
}
```

`bump` stores a number, and a number cannot dangle. The question only bites when a
function allocates and then stores what it allocated:

```nul
fn collect(out: *var List[Entry], arena: Arena, src: *Tree)
```

`out` is written through, and `arena` is where this function allocates, so anything
`collect` puts into `out` may live in `arena`. One rule makes that safe:

> **A function that takes an arena and a `*var` parameter requires its arena to outlive
> that parameter.**

Nobody writes that down. It follows from `*var` and from the single arena parameter, and
both of those are already in the signature for reasons that have nothing to do with
lifetimes. The caller has both names in scope and checks them the way it checks every
other store. The callee, having stated the requirement by taking the two parameters, may
store its own arena's memory into `out` without asking again.

A `*T` parameter carries no obligation at all, because a function that cannot write
through a pointer cannot make one dangle.

## One arena is a whole program

The three rules say what is possible, not what is required. The smallest program that
obeys all of them makes one arena, passes it down, and stops:

```nul
fn main() !i64 {
    var arena = Arena.init()

    let tree = try parse(arena, "input.txt")
    let report = try analyze(arena, tree)

    return report.score
}
```

No child, no `reset`, no `destroy`. Nothing crosses an arena, because there is only one
arena to cross. Every check the compiler makes compares where a value lives against where
it is being put, and here those are the same name every time, so the checker is not quiet
by luck. It has nothing to say about a program written this way, and it never will.

The cost is one parameter on a function that allocates, which is a parameter you were
writing anyway to say where its memory comes from. That is the complete memory vocabulary
of such a program.

What it gives up is reclamation. Memory grows with everything the program ever allocates
rather than with what it is still using, and the release comes at the end of `main`. For
a program that runs, produces an answer, and exits, that is not a compromise, it is the
design. A compiler, a converter, a one-shot tool: allocate freely, and let exit be the
free.

A loop is what changes the arithmetic. A server, a game, an editor, anything that runs
until it is told to stop, allocates without bound in time, and no amount of safety saves
a program that runs out of memory. `child` and `reset` exist for that moment and for no
other:

```nul
    while {
        var request = arena.child()          // dies at the end of every iteration
        try handle(request, try accept(socket))
    }
```

Nothing was rewritten to get here. `handle` takes an arena because it allocates, which was
true on the first day. Adding the child changed one line in the caller and no signature
anywhere, because the parameter was always doing both jobs. A program only starts reading
it as a lifetime once it has more than one.

## Aliasing is unrestricted

Any number of pointers may refer to one object, and every one of them may write through
it. There is no exclusivity rule, no distinction between a shared reference and a mutable
one, and no analysis tracking which pointer may act at which moment.

This is the decision that makes `b.parent = a` above ordinary code. A language that
enforces exclusivity has to give the programmer a vocabulary for saying which reference is
live and for how long, and that vocabulary is exactly what this model exists to avoid.

### What that costs, and why arenas absorb it

A write through one pointer can surprise code holding another. Here is the classic shape:

```nul
struct Entry {
    count: i64
}

var list = List[Entry].init(arena, .{ cap: 2 })
list.push(.{ count: 1 })

var first = list.at(0)            // a pointer into the list's buffer

list.push(.{ count: 2 })
list.push(.{ count: 3 })          // the buffer grew, so the list moved

first.count = 100                 // writes into the buffer the list abandoned

io.print("{list.at(0).count}\n")  // prints 1
```

In C++ the same code is a security vulnerability:

```cpp
std::vector<int> v = {1, 2, 3};
int* p = &v[0];
v.push_back(4);        // buffer reallocates, THE OLD BUFFER IS FREED
*p = 99;               // writing to freed memory, undefined behavior
```

There the allocator has taken that memory back and may already have handed it to something
else, so the write lands inside an unrelated object. The program corrupts data somewhere
far away, or crashes later, somewhere unconnected to this code.

In Nul it cannot, and the reason is rule two. **Nothing is freed individually**, so the
abandoned buffer was never returned to anyone. It is still memory owned by `arena`, and a
bump allocator only moves forward, so nothing else will ever be given that address while
the arena lives. `first.count = 100` is a legal write to live memory that nothing else
owns.

The result is a wrong number, not corruption. And the fix is one line:

```nul
list.at(0).count = 100            // fetch after mutating, not before
```

Two properties combine to make this true, and both are already in the model:

1. While an arena lives, memory is never recycled, so a stale pointer refers to memory
   nobody else has been given.
2. When an arena dies or resets, the compiler rejects every use of anything in it, so the
   one moment memory *is* recycled is the moment the checker is watching.

### Where this sits

Rust catches the stale pointer above, and charges `&mut` exclusivity for it. That is why a
graph or a doubly linked list in Rust means `Rc<RefCell<T>>`, an arena crate, integer
indices, or `unsafe`.

Nul takes the other side. `a.next = b` and `b.parent = a` are two lines that do what they
say, and the price is a bug class that produces a wrong value rather than corrupted
memory. Reading `1` where you expected `100` is a bug you can print your way out of.
Restructuring an aliased graph to satisfy a borrow checker is not.

## Cleanup is placed by the programmer and proven by the compiler

An arena dies at the end of the scope that declared it. That is the placement, and it is
one you wrote: putting `var scratch = arena.child()` in a scope is how you say how long
its memory lives. Nothing else is needed, and **an explicit release at the end of a scope
is always redundant**, because the arena was dying there anyway.

### What "no inserted cleanup" means

Two claims hide behind that phrase, and only one of them is about code.

The compiler decides **nothing** about when memory dies. Every arena in a program ends
somewhere you wrote: at the scope that declared it, or at a `reset` or `destroy` you
placed by hand. Writing `var scratch = arena.child()` in a scope *is* how you write its
release, because the scope is the statement of the lifetime. There is no destructor to
discover, no drop glue, and no cleanup threaded through a path you cannot see.

The compiler does **emit** that release, at the end of the scope you put the arena in and
nowhere else. What it costs depends on which arena it is. A child is a range inside its
parent, so its death is restoring the parent's offset. That is one store, and no allocator
is involved. A root arena owns pages from the operating system, so its death returns them,
which is one call at the end of the scope that made it. A program usually has one root
arena, in `main`.

So the guarantee is not that nothing runs at the end of a scope. It is that nothing runs
you did not ask for, and nothing runs anywhere but where you asked for it.

`reset` and `destroy` exist to depart from that default, both of them *earlier*. `reset`
discards everything in the arena and keeps the arena, which is what makes the scratch loop
work. `destroy` ends the arena before its scope does, for a function that is finished with
its scratch long before it returns.

```nul
fn process(arena: Arena, items: []Item) {
    var scratch = arena.child()

    for item in items {
        let work = expand(scratch, item)     // temporaries for this item
        record(arena, work)                  // the part that is kept

        scratch.reset()                      // discard the temporaries
    }
}
```

The compiler never *infers* a cleanup point. Every arena in a program dies somewhere the
programmer put it: at the scope where it was declared, or at a `reset` or `destroy`
written by hand. What the compiler will not do is decide that an arena could die sooner
than you said, move a release to where it thinks the last use is, or thread cleanup
through paths you cannot see. It verifies the placement you chose, proving no value
belonging to that arena is used after the point where the arena dies. Move the reset one
line too early and it says so:

```nul
    var item = scratch.create[Item]()
    item.weight = 42

    scratch.reset()

    return item.weight            // rejected
```

This distinction is the central design decision of the model. Inferring the correct
cleanup point is a whole program property: it makes the answer depend on code in other
files, and produces errors that cannot be localized or explained. Verifying a stated
cleanup point is local and decidable, and produces an error that names the value, names
the arena, names the line where the arena died, and names the last line where the value
was legitimately used.

You keep the control you would have in C, and gain a proof you could not have in C.

### Cleanup happens where the arena is named

`reset` and `destroy` are the two moments memory actually goes away, and proving nothing
survives them is a matter of comparing names inside one function. So those two operations
require a name: an arena parameter, or a local you made with `Arena.init` or `child`.

An arena reached through a pointer can be allocated from, the way `push` does above, but
it cannot be released:

```nul
self.arena.reset()                // rejected, 'self.arena' is not a name here
```

Allocating without knowing which region `self.arena` is stays safe, because the invariant
already settles the direction. Releasing does not, because every value in that region,
anywhere in the program, dies at that instant, and this function can see almost none of
them. Whoever created the arena can name it, and that is where the reset belongs.

### A destroy inside a loop

The `process` loop above resets rather than destroys, and that is not a stylistic choice.
`reset` discards the arena's memory and keeps the arena, so the next iteration allocates
into it again. `destroy` ends the arena itself, so there is nothing left for the next
iteration to allocate from:

```nul
    for item in items {
        let work = expand(scratch, item)
        record(arena, work)

        scratch.destroy()                    // rejected: 'scratch' was made outside
    }                                        // this loop
```

This is the placement rule read at a loop. `scratch` was declared outside, so the scope
that ends it is outside, and a release written inside the body runs once per pass. An
arena declared *inside* the body already has its death at the end of each iteration,
where the programmer put it, so there is nothing to reject:

```nul
    for item in items {
        var pass = arena.child()             // dies at the end of every iteration
        // ...
    }
```

Those are the two shapes a loop wants: `reset` for an arena that outlives the loop, and a
child inside the body for one that does not.

## Relationships that outlive an arena

Some relationships genuinely span different lifetimes, such as a long lived reference to
objects created and destroyed over time. For these, store an identity rather than an
access path:

```nul
struct Handle {
    slot: u32                     // an index, not a pointer
}

fn remember(arena: Arena, position: u32) *Handle {
    var h = arena.create[Handle]()
    h.slot = position             // a plain number crosses arenas freely
    return h
}
```

An index is a number, so it is always safe to store anywhere, and reaching the data means
going back through the collection, which is visibly alive at the point of use. A stale
index produces a wrong answer or a reported error, which is a logic bug you can debug,
rather than corrupted memory, which is not. The standard library provides a pool type with
generational indices so staleness itself can be detected.

For the rare case of data with many owners and individually determined lifetimes, the
standard library provides a reference counted type. It is a library type rather than a
language feature, it is written out at every use, and a program that does not import it
contains none of its machinery. The core language inserts no code, ever.

## The model in one page

What the programmer writes:

- An arena, wherever memory should come from, and a child arena wherever temporaries
  belong.
- `*T` to read through a pointer, `*var T` to write through one.
- A `reset` or `destroy` when memory should go away earlier than the enclosing scope.

That is the complete set of memory related things a Nul program says. There is no lifetime
syntax, no ownership qualifier, no move semantics to learn, no `Rc`, no `Box`, no
`unsafe`, and no region parameter in any type.

What the compiler guarantees:

- Every value in an arena outlives every pointer that can reach it, so no pointer ever
  refers to dead memory.
- No use of any value belonging to an arena after that arena dies or resets.
- No destructor run and no cleanup path you did not write. The one release the compiler
  emits is the one you placed, at the scope you placed it in.

What it does not attempt:

- It does not restrict aliasing, so stale pointers into a container that has grown are
  possible. Arenas turn that into a wrong value rather than a memory error, because
  nothing is freed individually.
- It does not infer where an arena should die, so the placement is always yours, and only
  the proof is the compiler's.

The trade the model makes, stated plainly: it gives up per object lifetimes, which are
what force annotations and exclusivity into every other safe systems language, and gets
back a checker that is local, a vocabulary that is empty, and code that can build a cyclic
graph in the two lines that a cyclic graph deserves.
