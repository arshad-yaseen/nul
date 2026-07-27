# TODO

Ordered by what unblocks the most. The three items under **Unblocking** are what turn Nul
from a checker with a backend into a language you can write a real program in; almost
everything below them is easier to design once they exist.

## Unblocking

- [ ] **Control flow: `if`, `for`.** Nothing algorithmic can be written without it, and it
      forces the largest single migration in the compiler:
  - [ ] `Nir` gains blocks and terminators
  - [ ] locals become `alloc`/`store`/`load`. `Lower.assignLocal`'s `local.inst = value`
        only works because bodies are straight line
  - [ ] `Region`'s `Info.released: u32` becomes a forward dataflow over the CFG. Union at
        joins is the *may* answer and the safe one; keeping the *must* answer too is what
        separates "is used after" from "may be used after"
  - [ ] `codegen/c.zig` must hoist temp declarations to the top of the function; a C local
        declared inside a branch is not visible after it
  - [ ] `Lower.endScope` becomes cleanup-on-every-path
- [ ] **Slices, `[]T`.** The largest gap in the type system, and the one that can still
      teach us something about the memory model: what region does `slice[i]` carry, and
      does a slice of pointers behave? `str` is already an immutable `[]u8`.
- [ ] **Modules and multi-file compilation.** `use std.io` resolves to nothing today, so
      there is nowhere to put a standard library.

## Language

- [ ] Error unions, `!T`. `README.md`'s own example does not compile without them
- [ ] Narrowing conversions: `i32(x)` checked and trapping, `i32.wrap(x)` explicit.
      Widening is already implicit and stays that way
- [ ] Generics with constraints, checked once at the definition (`spec.md`)
- [ ] Decide and write down: nested functions (recommend no), closures (need a decision
      before anything depends on them)
- [ ] Does `create` zero its memory? The C backend hands back whatever `malloc` gave, so
      an unset field is garbage today. Decide the semantics, then enforce them

## Memory model and checker

- [ ] **Concurrency.** Zero mentions across `README.md`, `spec.md` and `memory_model.md`.
      Arenas plus threads may constrain `Arena` itself, so sketch it before the stdlib
- [ ] Write the branch case as a `test/fail` file *now*, before the CFG exists, so the
      wording is designed rather than discovered. A release inside one arm with the use
      after the join has no single line to blame
- [ ] `arena.destroy()` followed by `arena.create()` is not caught: `Region.checkLive`
      skips operands whose type is `Arena`, which is right for a handle surviving its own
      reset and wrong for one that was destroyed
- [ ] Write `List`, `HashMap` and a graph in Nul. Not as features, as experiments: they
      decide whether the model survives contact with real data structures
- [ ] Arena operations are `Nir` instructions. `memory_model.md` calls `copy` "an ordinary
      library function", so long term they should be calls with a known callee

## Codegen

- [ ] Name mangling. A function named `int` or `switch` emits broken C; only `main` is
      handled
- [ ] A type table, so nested and generated types get names instead of being spelled
      structurally at each use
- [ ] `usize` maps to `uintptr_t`; it should be `size_t`
- [ ] Explicit casts from `void *`, so the output is also valid C++
- [ ] `str` escapes pass through assuming Nul and C agree, which will not hold
- [ ] Arena helpers have external linkage, so two generated files would collide
- [ ] `reset` does not reclaim children: a child mallocs its own block, so a parent reset
      leaves it until scope end. Safe, but it holds memory longer than it should

## Diagnostics

- [ ] Parse errors carry no code. `Ast.Error` has its own tag type, so the range wants
      assigning deliberately rather than by accident
- [ ] `nul explain E0007`, now that codes are stable

## Tooling

- [ ] `nul dump <file>` for token, AST and NIR inspection, dropped when `main.zig` went
- [ ] `nul build` could invoke the C compiler rather than printing a path

## Documentation

- [ ] `README.md`'s example uses `!*Node` and does not compile
- [ ] `spec.md` is one line. Everything the language has settled lives in commit messages
      and in this file instead
- [ ] Write down the direction: phase-structured programs, Go-shaped surface, systems
      semantics. It is the reason to choose Nul and it is stated nowhere

## Demos

- [ ] An arena-per-request server. The shortest path from "interesting research" to "I
      want to use this", and it stresses the model exactly where its domain lives
