# Nul

A systems programming language with compile time memory safety and no runtime.

```zig
fn main() {
    var mem = arena()
    let text = try fs.read(mem, "data.csv")

    for line in text.lines() {
        print(line)
    }
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
