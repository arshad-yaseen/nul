# Nul

A research project exploring compile time memory safety for a systems language with no
runtime. Not usable, and not intended for use any time soon.

No garbage collector. No hidden allocations. No lifetime annotations.

The question the project is asking: how much of memory safety can be proven from the
allocator you were already passing down, without a borrow checker to learn?

```zig
use std.mem.Arena

struct Node {
    value: i64
    next: *Node
}

fn build(arena: Arena, value: i64) *var Node {
    var node = arena.create[Node]()
    node.value = value
    return node
}

fn main() i64 {
    var arena = Arena.init()
    var scratch = arena.child()   // dies at the end of this scope

    let kept = build(arena, 1)
    let temp = build(scratch, 2)

    kept.next = temp              // rejected: 'temp' dies before 'kept' does
    return kept.value
}
```

`arena` is where a function allocates. It is also the name of a lifetime, and you wrote
it because you needed somewhere to allocate from. That is the entire annotation budget.
[The model](memory.md) is one page, and the last line above is the only thing it rejects.

## Try it

```console
$ zig build
$ ./zig-out/bin/nul build program.nul -o program
$ ./program; echo $?
42
```

```
An entry is one file. Everything it imports is part of the program.

commands:
  check <entry>   report the type and memory mistakes in the program
  tree  <entry>   print one file's syntax tree
  ir    <entry>   print the typed IR
  c     <entry>   write the program as C
  build <entry>   compile the program to an executable

options:
  -o <path>        where to write the output
  --cc <program>   the C compiler to run (default: zig cc)
  --std <dir>      where the standard library lives
```

## Status

Design first, implementation second. The front end is real: parsing with recovery,
modules, generics instantiated on demand, and a typed control flow graph. The backend
emits C99 and compiles it.

The region checker is not written, so the rejection above is the model rather than the
implementation. Arenas do not reach the backend yet, and there is no IO, so a program
speaks through its exit code. Read this as a set of ideas, not a toolchain.
