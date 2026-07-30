# Nul

A research project exploring compile time memory safety for a systems language with no
runtime. Not usable, and not intended for use any time soon.

No garbage collector. No hidden allocations. No lifetime annotations.

The question the project is asking: how much of memory safety can be proven from the
allocator you were already passing down, without a borrow checker to learn?

```rust
use std.io
use std.mem.Arena

struct Order {
    name: str
    grams: u32

    fn postage(self: *Order) u32 {
        return self.grams / 500 + 3
    }
}

fn place(arena: Arena, name: str, grams: u32) !*var Order {
    if grams > 30000 {
        return error.TooHeavy
    }
    var order = arena.create[Order]()
    order.name = name
    order.grams = grams
    return order
}

fn quote(arena: Arena, grams: u32) !u32 {
    var scratch = arena.child()

    let draft = try place(scratch, "draft", grams)
    return draft.postage()
}

fn main() {
    var arena = Arena.init()

    let order = place(arena, "keyboard", 900) catch {
        io.print("too heavy to ship\n")
        return
    }
    io.print("{order.name} ships for {order.postage()}\n")

    let trial = quote(arena, 960) catch 0
    io.print("with a cable it would be {trial}\n")
}
```

## Status

Design first, implementation second. The compiler is incomplete, the surface will
change, and nothing here is stable. Read it as a set of ideas, not a toolchain.
