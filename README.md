# Nul

A research project exploring compile time memory safety for a systems language with no
runtime. Not usable, and not intended for use any time soon.

```zig
use std.io
use std.mem.Arena

let Node = struct {
    name: str
    prev: *Node
    next: *Node
}

fn load(arena: Arena, path: str) !*Node {
    var scratch = arena.child()      // dies when this function returns

    let text = try io.read_file(scratch, path)

    var head = arena.create(Node)
    var tail = head

    for line in text.lines() {
        var n = arena.create(Node)

        n.name = arena.copy(line)    // line lives in scratch, n must not
        n.prev = tail                // they point at each other, and nothing to declare
        tail.next = n
        tail = n
    }

    return head                      // text is gone, the list is not, and the compiler checked
}
```

No garbage collector. No hidden allocations. No lifetime annotations.

The question the project is asking: how much of memory safety can be proven from the
allocator you were already passing down, without a borrow checker to learn?

## Status

Design first, implementation second. The compiler is incomplete, the surface will
change, and nothing here is stable. Read it as a set of ideas, not a toolchain.
