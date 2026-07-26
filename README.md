# Nul

A systems programming language with compile time memory safety and no runtime.

```zig
use std.io
use std.mem.Arena
use std.list.List

let Entry = struct {
    key:   str
    value: i64
}

/// Entries live in `arena`. Everything the parse allocates dies with `scratch`.
fn parse(arena: Arena, scratch: Arena, path: str) !List(Entry) {
    let text = try io.read_file(scratch, path)
    var out = List(Entry).init(arena, .{ cap: 16 })

    for line in text.lines() {
        if line.is_empty() { continue }

        let parts = try line.split(scratch, "=")
        // parts points into text, which dies with scratch, so the key is copied
        out.push(.{ key: arena.dup(parts[0]), value: try parts[1].to_int() })
    }

    return out
}

pub fn main() !void {
    var arena = Arena.init()
    var scratch = arena.child()

    let entries = parse(arena, scratch, "app.conf") catch e {
        io.print("parse failed: {e}\n")
        return
    }

    scratch.reset()   // text and parts are gone. entries are not, and the compiler checked.

    io.print("{entries.len} entries\n")
}
```

Memory comes from arenas you create and pass down. An arena parameter does two jobs at
once, it is where the function allocates, and it is the name of a lifetime. You were
already writing it for the first reason, so the second is free.

Inside an arena, pointers work exactly as they do in C, because everything there dies
at the same instant. The one pointer the compiler rejects is the one that crosses
arenas, because that is the only way memory can die while a pointer to it survives.
You place the cleanup, and the compiler proves nothing reads the memory after it.

No garbage collector. No hidden allocations. No lifetime annotations, because the
allocator you already pass is the annotation.

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
