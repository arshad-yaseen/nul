# Nul

**As simple as Go, as bare as C. Memory safe at compile time, with nothing to annotate.**

A research project into systems programming without a runtime. Not usable, and not
intended for use any time soon.

No garbage collector. No hidden allocations. No lifetime annotations.

> How much of memory safety can be proven from the allocator you were already passing down, without a borrow checker to learn?

## Try it

```zig
struct Counter {
    hits: i64

    fn bump(self: *var Counter, by: i64) {
        self.hits = self.hits + by
    }
}

pub fn main() i64 {
    var counter: Counter = .{ hits: 0 }

    var i: i64 = 0
    while i < 13 {
        let step = if i % 2 == 0 { i } else { 0 }
        counter.bump(step)
        i = i + 1
    }

    return counter.hits
}
```

```console
$ zig build
$ ./zig-out/bin/nul run counter.nul
42
```

```
commands:
  run <entry>   check, compile, and run the program
  ir  <entry>   print the typed IR

options:
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
