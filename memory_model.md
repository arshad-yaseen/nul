# Nul Memory Model

## The contract

**Every Nul program is memory safe at compile time.** No program can read or write
memory after that memory has died, and the compiler proves it before the program runs.

There is no garbage collector, no runtime, and no compiler inserted cleanup code. The
programmer never writes lifetime annotations, never learns ownership or borrowing
vocabulary, and never fights an analysis they cannot see. What the programmer writes
is what executes.

The whole model is one sentence: **inside an arena there are no rules, between arenas
there is one.**

Inside, you may write anything C lets you write. Cycles, back pointers, graphs,
intrusive lists, a dozen pointers to one object all writing through it. None of it
needs proving, because none of it can dangle. Everything in an arena dies at the same
instant, so a pointer and its target cannot outlive each other:

```nul
let Node = struct {
    name: str
    prev: *Node
    next: *Node
}

fn append(arena: Arena, tail: *Node, name: str) *Node {
    var n = arena.create(Node)

    n.name = name
    n.prev = tail                 // they point at each other
    tail.next = n                 // and there is nothing to declare

    return n
}
```

Between arenas, one rule: a pointer may not outlive what it points at. That is the
only thing the compiler checks, and checking it needs nothing you were not already
writing down.

The rest of this document explains why the model needs nothing more.

## Rule one, everything is a value

Assignment and argument passing behave as if the value were copied.

```nul
let Point = struct {
    x: i64
    y: i64
}

var a: Point = .{ x: 1, y: 2 }
var b = a                         // a copy
b.x = 99

// a.x is still 1
```

There is no way for two names to disagree about the state of one object, because there
is no way for two names to *be* one object, unless you wrote a pointer:

```nul
var a = arena.create(Point)       // a is a *Point
var b = a                         // b is the same pointer
b.x = 99

// a.x is 99, because a and b are the same object
```

The compiler is free to turn a copy into a move or a borrow whenever the difference
cannot be observed, which is where the performance comes from. That optimization is
unobservable rather than hidden. Nothing a programmer can measure changes.

This rule is what makes the rest of the model tractable: **the only aliasing in a
program is aliasing the programmer wrote down as a pointer.**

## Rule two, memory comes from arenas

There is no global heap and no implicit allocator. Memory comes from an arena, which
is an object you create, choose the backing storage for, and pass down to anything
that needs to allocate.

```nul
pub fn main() !void {
    var arena = Arena.init()

    let tree = try parse(arena, "input.txt")

    io.print("{tree.count} nodes\n")
}
```

Arenas nest, so an arena can draw from a parent. A function that needs temporary space
makes a child, and the child dies when the function returns:

```nul
fn parse(arena: Arena, path: str) !*Tree {
    var scratch = arena.child()          // dies at the end of this function

    let text = try io.read_file(scratch, path)   // temporary
    var tree = arena.create(Tree)                // the result

    // ... fill in tree from text ...

    return tree
}
```

Every allocated value belongs to exactly one arena, and its lifetime is that arena's
lifetime. **Nothing is freed individually.** When an arena dies, everything in it dies
at the same instant, in one bulk operation.

### The parameter is doing two jobs

Look again at the signature:

```nul
fn parse(arena: Arena, path: str) !*Tree
```

`arena` is where the function allocates. It is *also* the name of a lifetime. You
wrote it because you needed somewhere to allocate from; the compiler reads it as the
region tag it needs for checking.

This is why the model costs zero annotations. The information the compiler needs is
information you were already writing for your own reasons.

### One arena per function

The sentence above only works if "the arena" names something. With two arena
parameters it would not, and a caller would have no way to know which one a result
lives in. So a function allocates its results into exactly one arena, and taking a
second is rejected:

```nul
fn analyze(long: Arena, short: Arena, input: str) *Report {
    var r = long.create(Report)
    r.lines = 0
    return r
}
```

```
error: 'analyze' takes more than one arena, so its result has no single home

  ┌─ analyze.nul:9:25
  │
9 │ fn analyze(long: Arena, short: Arena, input: str) *Report {
  │            ───────────  ^^^^^^^^^^^^              ───────  which arena is this in?
  │            │            │
  │            │            a second arena parameter
  │            the first arena parameter
  │
  = note: a function allocates its results into exactly one arena. That rule is
          what lets a caller know where a result lives without anyone writing a
          lifetime down.
  = help: drop 'short', and create a child inside the body for temporaries
            fn analyze(long: Arena, input: str) *Report {
                var short = long.child()
```

A function that needs scratch space does not take a second arena. It makes a child,
which dies when the function returns:

```nul
fn analyze(long: Arena, input: str) *Report {
    var short = long.child()
    // ...
}
```

That is the natural shape anyway, and it is worth stating as the rule behind the rule:
**what you take from outside is for what outlives the call, and what you make inside is
for what does not.** Scratch space is an implementation detail. A caller forced to
supply one is being told about memory it will never see, and being asked to decide
something it cannot know.

The rule is about arenas, not about pointers. Take as many pointer parameters as you
like, because a pointer already carries the region it came from:

```nul
fn record(out: *List(Entry), arena: Arena, e: Entry)
```

Only allocation needs an arena, and results come from exactly one of them. That single
restriction is what buys every signature in the language the property of saying where
its result lives, while saying nothing at all.

## Rule three, pointers are free inside an arena, checked across arenas

Inside one arena, pointers behave exactly as they do in C. Store them in structs,
return them, hold them in collections, build linked lists, trees, graphs, and
intrusive structures. No restrictions, no overhead, cycles included:

```nul
let Node = struct {
    value:  i64
    next:   *Node
    parent: *Node
}

fn link(arena: Arena) *Node {
    var a = arena.create(Node)
    var b = arena.create(Node)

    a.next = b
    b.parent = a                  // a and b point at each other, and that is fine

    return a
}
```

This is safe by construction rather than by analysis. Everything in one arena dies at
one moment, so a pointer and the thing it points to cannot outlive each other. There
is no ordering to get wrong.

### The one thing the compiler rejects

A pointer that crosses arenas, meaning memory from one arena stored inside something
belonging to another, or returned to a scope that does not own the arena it lives in:

```nul
fn leak(arena: Arena) *Box {
    var scratch = arena.child()

    var box = arena.create(Box)
    var temp = scratch.create(i64)

    box.item = temp               // rejected: 'temp' dies before 'box' does

    return box
}
```

```
error: 'temp' does not live long enough

   ┌─ leak.nul:14:16
   │
 9 │     var scratch = arena.child()
   │         ───────  'scratch' is created here, as a child of 'arena'
   ·
11 │     var box = arena.create(Box)
   │         ───  'box' lives in 'arena'
12 │     var temp = scratch.create(i64)
   │         ────  'temp' lives in 'scratch'
   ·
14 │     box.item = temp
   │     ────────   ^^^^  this points into 'scratch'
   │     │
   │     this memory lives in 'arena'
   ·
16 │     return box
   │            ───  'box' escapes here, so it outlives 'scratch'
   │
   = note: 'scratch' is a child of 'arena', and a child dies before its parent.
           'box.item' would still point into it after line 17.
   = help: copy the value into the arena that outlives it
             box.item = arena.copy(temp)
```

This is the only situation in which memory can die while a pointer to it survives, so
it is the only situation the checker polices.

### Which direction is allowed

Only one of the two directions can dangle, and only that one is rejected:

| storing | into | verdict |
|---|---|---|
| `arena` memory | `arena` memory | free, same lifetime |
| `arena` memory | `scratch` memory | free, the parent outlives the child |
| `scratch` memory | `arena` memory | **rejected**, the child dies first |
| sibling child | sibling child | **rejected**, neither outlives the other |

The second row is worth noticing. Long lived memory may be stored inside short lived
memory, always:

```nul
fn stash(arena: Arena) {
    var scratch = arena.child()

    var holder = scratch.create(Ref)
    holder.target = arena.create(i64)     // fine, 'arena' outlives 'scratch'
}
```

### Copying between arenas

`copy` is how a value moves from one arena to another. It copies the bytes a value
directly owns, for a number that is the number, for a `str` it is the characters.

A type that holds a pointer cannot be copied at all:

```nul
let Pair = struct {
    left:  *Inner
    count: i64
}

fn keep(arena: Arena, p: Pair) Pair {
    return arena.copy(p)          // rejected, 'Pair' holds a pointer
}
```

Copying `Pair` would move the struct into the new arena and leave `left` pointing into
the old one. That is exactly what rule three forbids, except hidden inside a value
that looks fine from outside, so the compiler refuses at the copy rather than let a
laundered pointer escape.

Nothing about this is special cased in the language. `Arena.copy` is an ordinary
library function whose signature says its argument must be pointer free, and the
compiler answers that question about a type the way it answers any other compile time
question. The region of the result needs no special case either: `copy` takes one
arena, so its result lives in that arena, by the rule already stated.

To move something that does hold pointers, copy what the pointers reach and rebuild
around it:

```nul
var q = arena.create(Pair)

q.left = arena.create(Inner)
q.left.value = p.left.value
q.count = p.count
```

### The check is local

Every value carries the arena it came from, and arenas are named by parameters already
in scope, so the check compares two names that both appear in the same function. It
never requires whole program analysis, never crosses module boundaries, and never
depends on what code elsewhere happens to do.

### Parameters may always borrow

Function parameters are exempt from all of this, for reading and for mutation. A
borrowed parameter cannot outlive the call that created it, so there is nothing to
track:

```nul
fn bump(c: *Counter, by: i64) {
    c.hits = c.hits + by          // no arena, nothing to check
}
```

The common case of passing data into a function to read or modify it needs no thought
at all.

## Aliasing is unrestricted

Any number of pointers may refer to one object, and every one of them may write
through it. There is no exclusivity rule, no distinction between a shared reference
and a mutable one, and no analysis tracking which pointer may act at which moment.

This is the decision that makes `b.parent = a` above ordinary code. A language that
enforces exclusivity has to give the programmer a vocabulary for saying which
reference is live and for how long, and that vocabulary is exactly what this model
exists to avoid.

### What that costs, and why arenas absorb it

A write through one pointer can surprise code holding another. Here is the classic
shape:

```nul
let Entry = struct {
    count: i64
}

var list = List(Entry).init(arena, .{ cap: 2 })
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

There the allocator has taken that memory back and may already have handed it to
something else, so the write lands inside an unrelated object. The program corrupts
data somewhere far away, or crashes later, somewhere unconnected to this code.

In Nul it cannot, and the reason is rule two. **Nothing is freed individually**, so
the abandoned buffer was never returned to anyone. It is still memory owned by
`arena`, and a bump allocator only moves forward, so nothing else will ever be given
that address while the arena lives. `first.count = 100` is a legal write to live
memory that nothing else owns.

The result is a wrong number, not corruption. And the fix is one line:

```nul
list.at(0).count = 100            // fetch after mutating, not before
```

Two properties combine to make this true, and both are already in the model:

1. While an arena lives, memory is never recycled, so a stale pointer refers to
   memory nobody else has been given.
2. When an arena dies or resets, the compiler rejects every use of anything in it, so
   the one moment memory *is* recycled is the moment the checker is watching.

### Where this sits

Rust catches the stale pointer above, and charges `&mut` exclusivity for it. That is
why a graph or a doubly linked list in Rust means `Rc<RefCell<T>>`, an arena crate,
integer indices, or `unsafe`.

Nul takes the other side. `a.next = b` and `b.parent = a` are two lines that do what
they say, and the price is a bug class that produces a wrong value rather than
corrupted memory. Reading `1` where you expected `100` is a bug you can print your way
out of. Restructuring an aliased graph to satisfy a borrow checker is not.

## Cleanup is placed by the programmer and proven by the compiler

An arena dies at the end of its scope by default. You may also reset or destroy one
earlier, which is what makes the scratch arena pattern work:

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

The compiler never decides when memory should be freed, and never inserts a free you
did not write. It verifies the placement you chose, proving no value belonging to that
arena is used after the point where the arena dies. Move the reset one line too early
and it says so:

```nul
    var item = scratch.create(Item)
    item.weight = 42

    scratch.reset()

    return item.weight            // rejected
```

```
error: 'item' is read after 'scratch' was released

   ┌─ weigh.nul:17:12
   │
12 │     var item = scratch.create(Item)
   │         ────  'item' lives in 'scratch'
   ·
15 │     scratch.reset()
   │     ───────────────  everything in 'scratch' dies here
   ·
17 │     return item.weight
   │            ^^^^^^^^^^^  read after its memory was released
   │
   = help: read the value before the reset
             let weight = item.weight
             scratch.reset()
             return weight
```

This distinction is the central design decision of the model. Inferring the correct
cleanup point is a whole program property: it makes the answer depend on code in other
files, and produces errors that cannot be localized or explained. Verifying a stated
cleanup point is local and decidable, and produces an error that names the value,
names the arena, names the line where the arena died, and names the last line where
the value was legitimately used.

You keep the control you would have in C, and gain a proof you could not have in C.

## Relationships that outlive an arena

Some relationships genuinely span different lifetimes, such as a long lived reference
to objects created and destroyed over time. For these, store an identity rather than
an access path:

```nul
let Handle = struct {
    slot: usize                   // an index, not a pointer
}

fn remember(arena: Arena, position: usize) *Handle {
    var h = arena.create(Handle)
    h.slot = position             // a plain number crosses arenas freely
    return h
}
```

An index is a number, so it is always safe to store anywhere, and reaching the data
means going back through the collection, which is visibly alive at the point of use. A
stale index produces a wrong answer or a reported error, which is a logic bug you can
debug, rather than corrupted memory, which is not. The standard library provides a
pool type with generational indices so staleness itself can be detected.

For the rare case of data with many owners and individually determined lifetimes, the
standard library provides a reference counted type. It is a library type rather than a
language feature, it is written out at every use, and a program that does not import
it contains none of its machinery. The core language inserts no code, ever.
