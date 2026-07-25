# Nul

A systems programming language with compile time memory safety and no runtime.

```nul
use std/io
use std/mem { Arena }
use std/list { List }

pub fn main() !void {
    var a = Arena.init()
    var scratch = a.child()

    let src = try io.read_file(scratch, "input.txt")

    let tokens = lex(a, src) catch e {
        match e {
            bad_byte b: io.print("lex failed: byte 0x{b.byte:x} at {b.at}\n")
        }
        return
    }
    scratch.reset()  // `src` is done with, the compiler checks

    for t, i in tokens {
        io.print("{i:3}  {describe(t, scratch)}\n")
        scratch.reset()
    }

    io.print("{tokens.len} tokens\n")
}

let Token = enum {
    number: i64
    word:   str
    symbol: u8
}

let LexError = enum {
    bad_byte: struct { byte: u8, at: usize }
}

fn lex(a: Arena, src: str) LexError![]Token {
    var out = List(Token).init(a, { cap: src.len / 4 + 8 })
    var i: usize = 0

    for i < src.len {
        let c = src[i]

        if c == ' ' or c == '\n' {
            i = i + 1
        } else if c.is_digit() {
            var n: i64 = 0
            for i < src.len and src[i].is_digit() {
                n = n * 10 + (src[i] - '0') as i64
                i = i + 1
            }
            out.push(Token.number(n))
        } else if c.is_alpha() {
            let start = i
            for i < src.len and src[i].is_alnum() { i = i + 1 }
            out.push(Token.word(a.dup(src[start..i])))
        } else if c.is_punct() {
            out.push(Token.symbol(c))
            i = i + 1
        } else {
            return LexError.bad_byte({ byte: c, at: i })
        }
    }

    return out.slice()
}

fn describe(t: Token, a: Arena) str {
    return match t {
        number n: str.fmt(a, "number {n}")
        word w:   str.fmt(a, "word {w}")
        symbol s: str.fmt(a, "symbol {s:c}")
    }
}

test "lexes a small expression" {
    var a = Arena.init()

    let ts = try lex(a, "x1 + 42")

    assert(ts.len == 3)
    assert(ts[2] == Token.number(42))
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
nul check               types and memory only, no codegen — this is what the editor runs
nul fmt                 format in place; there are no options
nul doc                 extract documentation from /// comments
nul lsp                 language server, spoken by the same binary
```

Cross compilation is a flag, because the compiler ships every target it supports:

```
nul build --target aarch64-linux
nul build --target riscv32-freestanding --release
```

`nul check` is separate from `nul build` on purpose: memory safety is a type-level
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

`build.nul` is a program, not a configuration format:

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
