# Zol

**As simple as Go, as bare as C. Memory safe at compile time, with nothing to annotate.**

A research project into systems programming without a runtime. Not usable, and not
intended for use any time soon.

No garbage collector. No hidden allocations. No lifetime annotations.

> How much of memory safety can be proven from the allocator you were already passing down, without a borrow checker to learn?

## Try it

```console
$ zig build
$ ./zig-out/bin/zol check demo.zol
$ ./zig-out/bin/zol ir demo.zol
```

```
commands:
  check <entry>   check the program and report what is wrong
  ir    <entry>   print the typed IR

options:
  --std <dir>           where the standard library lives
  --color auto|on|off   colour the output (default: auto)
  --version             print the version
```

## Status

Design first, implementation second. The front end is real: parsing with recovery,
modules, generics instantiated on demand, and a typed control flow graph. It ends
there: `zol` checks a program and prints its IR, and nothing runs.

Nothing about memory is checked either. Arenas type check and lower like any other
value, so memory safety is the model rather than the implementation. Read this as a
set of ideas, not a toolchain.
