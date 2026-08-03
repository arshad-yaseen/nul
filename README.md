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
$ ./zig-out/bin/nul check counter.nul
$ ./zig-out/bin/nul ir counter.nul
fn Counter.bump(self: *var Counter, by: i64)
b0:
  %0 = param self : *var Counter
  ...
```

```
commands:
  check <entry>   check the program and report what is wrong
  ir    <entry>   print the typed IR

options:
  --std <dir>   where the standard library lives
```

## Status

Design first, implementation second. The front end is real: parsing with recovery,
modules, generics instantiated on demand, and a typed control flow graph. It ends
there: `nul` checks a program and prints its IR, and nothing runs.

The region checker is not written either, so memory safety is the model rather than
the implementation. Read this as a set of ideas, not a toolchain.
