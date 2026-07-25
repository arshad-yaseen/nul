# Nul

A systems programming language with compile time memory safety and no runtime.

```nul
use std/io
use std/mem { Arena }
use std/str

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
                n = n * 10 + (src[i] - '0').cast(i64)
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

    for t, i in tokens {
        io.print("{i:3}  {t.describe(scratch)}\n")
        scratch.reset()
    }

    io.print("{tokens.len} tokens\n")
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

## Status

Early. The design is settled, the compiler is not. Not usable yet.

## Why

C gives you control without safety. Rust gives you safety at the cost of a borrow
checker you have to learn. Go gives you simplicity at the cost of a garbage collector.
Nul keeps the control, keeps the simplicity, and moves the safety proof into something
you were already writing, which is the allocator you pass down.
