# Nul

A systems programming language with compile time memory safety and no runtime.

```zig
use std.io
use std.mem.Arena
use std.list.List

/// Words live in `arena`. The file text dies with `scratch`.
fn words(arena: Arena, scratch: Arena, path: str) !List(str) {
    let text = try io.read_file(scratch, path)
    var out = List(str).init(arena, .{ cap: 64 })

    for word in text.split(scratch, " ") {
        out.push(arena.dup(word))   // word points into text, so copy it
    }
    return out
}

pub fn main() !void {
    var arena = Arena.init()
    var scratch = arena.child()

    let found = try words(arena, scratch, "input.txt")
    scratch.reset()   // text is gone. found is not, and the compiler checked.

    io.print("{found.len} words\n")
}
```

No garbage collector. No hidden allocations. No lifetime annotations. Nothing new to learn.

The full model is in [memory_model.md](memory_model.md).

## Tooling

One binary. No package manager to install separately, no formatter to configure, no
language server to wire up by hand.

```
nul run main.nul        build and run
nul build               build the project described by build.nul
nul test                run every test block in the project
nul check               types and memory only, no codegen, what the editor runs
nul fmt                 format in place, no options
nul doc                 extract documentation from /// comments
nul lsp                 language server, spoken by the same binary
```

Cross compilation is a flag, because the compiler ships every target it supports.

```
nul build --target aarch64-linux
nul build --target riscv32-freestanding --release
```

`nul check` is separate from `nul build` on purpose. Memory safety is a type-level
property here, so your editor can tell you a pointer escapes its arena without ever
running the backend.

## Project layout

```
myproject/
  build.nul          the build, written in Nul
  src/
    main.nul         entry point
    lexer.nul        a file is a struct, `use .lexer` imports it
  deps/              vendored, checked in, versioned by you
```

`build.nul` is a program, not a configuration format.

```nul
use std.build

pub fn configure(b: *var build.Builder) {
    let exe = b.executable("myproject", "src/main.nul")
    exe.optimize(b.mode)
    exe.link_c()
    b.install(exe)
}
```

Dependencies are directories under `deps/`, imported by path like any other file.
There is no central registry, no lockfile format to learn, and no build step that
downloads code you did not read.

## Status

Early. The design is settled, the compiler is not. Not usable yet.

## Why

C gives you control without safety. Rust gives you safety at the cost of a borrow
checker you have to learn. Go gives you simplicity at the cost of a garbage collector.

Nul keeps the control, keeps the simplicity, and moves the safety proof into something
you were already writing, which is the allocator you pass down.
