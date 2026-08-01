# Nul

A research project exploring compile time memory safety for a systems language with no
runtime. Not usable, and not intended for use any time soon.

No garbage collector. No hidden allocations. No lifetime annotations.

The question the project is asking: how much of memory safety can be proven from the
allocator you were already passing down, without a borrow checker to learn?

```zig
use std.mem.Arena

pub struct Box[T] {
    item: T
}

pub struct Pair[K, V] {
    key: K
    value: V
}

pub type IntBox = Box[i64]
pub type Nested = Box[Box[i64]]

pub fn make[T](arena: Arena, v: T) *var Box[T] {
    let b = arena.create[Box[T]]()
    return b
}

fn main() {
    var arena = Arena.init()

    _ = make[i64](arena, 1)
    _ = arena.create[Pair[i64, bool]]()
}
```

## Status

Design first, implementation second. The compiler is incomplete, the surface will
change, and nothing here is stable. Read it as a set of ideas, not a toolchain.
