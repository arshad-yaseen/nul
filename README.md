# Nul

A systems programming language with compile time memory safety and no runtime.

```zig
use std.io
use std.fs

fn main() !void {
    let a = arena()

    let text = try fs.read_text(a, "notes.txt")

    var lines = 0
    for _ in text.lines() {
        lines += 1
    }

    io.print("{lines} lines\n")
}
```

Memory lives in arenas you create and pass. Pointers inside an arena work like C.
Pointers that cross arenas are a compile error. You choose where cleanup happens and
the compiler proves nothing uses the memory afterwards.

No garbage collector. No hidden allocations. No lifetime annotations.

## Status

Early. The design is settled, the compiler is not. Not usable yet.

## Why

C gives you control without safety. Rust gives you safety at the cost of a borrow
checker you have to learn. Go gives you simplicity at the cost of a garbage collector.
Nul keeps the control, keeps the simplicity, and moves the safety proof into something
you were already writing, which is the allocator you pass down.
