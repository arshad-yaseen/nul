# Nul

Fast, safe, simple.

Nul is a systems programming language. Every program is memory safe
at compile time. There is no garbage collector, no runtime, no hidden
allocation and no hidden control flow. What you write is what executes.

## Why

Rust is safe but hard to learn. Zig is simple but not safe. Go is easy
but needs a garbage collector. Nul aims for all three corners at once.
You write code that reads like a scripting language, it runs like C,
and the compiler proves it safe.

## A taste

```
import fs

fn main() !Error {
    let mem = arena()
    let text = try fs.read(mem, "data.csv")

    var rows = list(Row, mem)
    for line in text.lines() {
        rows.push(try Row.parse(line))
    }

    print("parsed {rows.len} rows")
}
```

No lifetimes. No borrow checker to fight. No manual free.
Memory lives in arenas and the compiler proves nothing escapes.

## How it works

- Everything is a value. Nothing aliases, so nothing dangles.
- Memory comes from arenas. Everything in one dies together.
- References never outlive a function call, so checking is
  local and no annotations are needed.
- Shared ownership is an explicit library type, not a hidden cost.

## Status

Early. The design is documented in [spec.md](spec.md) and the
compiler is under active development. Nothing is stable yet.

## Roadmap

- [ ] Lexer and parser
- [ ] Type checker
- [ ] Escape checker
- [ ] C backend
- [ ] Self hosted formatter
