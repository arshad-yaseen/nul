# Nul

A systems programming language with compile time memory safety and no runtime.

```nul
use std/io
use std/mem { Arena }
use std/list { List }

let Token = enum {
    number: i64
    word:   str
}

fn lex(arena: Arena, src: str) !List(Token) {
    var out = List(Token).init(arena, { cap: src.len / 4 })
    var i: usize = 0

    for i < src.len {
        let c = src[i]
        let start = i

        if c.is_space() {
            i = i + 1
        } else if c.is_digit() {
            for i < src.len and src[i].is_digit() { i = i + 1 }
            out.push(Token.number(try src[start..i].to_int()))
        } else if c.is_alpha() {
            for i < src.len and src[i].is_alnum() { i = i + 1 }
            out.push(Token.word(arena.dup(src[start..i])))
        } else {
            return error.bad_byte
        }
    }

    return out
}

pub fn main() !void {
    var arena = Arena.init()
    var scratch = arena.child()

    let src = try io.read_file(scratch, "input.nul")

    let tokens = lex(arena, src) catch e {
        io.print("lex failed: {e}\n")
        return
    }

    scratch.reset()        // src is gone. tokens live in arena, and the compiler checked that.

    io.print("{tokens.len} tokens\n")
}

test "numbers and words" {
    var arena = Arena.init()
    let ts = try lex(arena, "x1 42")

    assert(ts.len == 2)
    assert(ts[1] == Token.number(42))
}
```

Memory lives in arenas you create and pass. Pointers inside an arena work like C.
Pointers that cross arenas are a compile error. You choose where cleanup happens and
the compiler proves nothing uses the memory afterwards.

No garbage collector. No hidden allocations. No lifetime annotations.

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
    lexer.nul        a file is a struct, `use ./lexer` imports it
  deps/              vendored, checked in, versioned by you
```

`build.nul` is a program, not a configuration format.

```nul
use std/build

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
