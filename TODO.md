# TODO

Ordered by what unblocks the most. The three items under **Unblocking** are what turn Nul
from a checker with a backend into a language you can write a real program in; almost
everything below them is easier to design once they exist.

## Unblocking

- [x] **Control flow: `if`, `for`.** Done, and it was the largest single migration in the
      compiler:
  - [x] `Nir` is a CFG: blocks with one terminator each (`jump`, `branch`, `ret`)
  - [x] a `var` is an `alloc` slot with `store`/`load`; a `let` and a parameter stay
        direct references, and an arena local is always direct, so releases act on names
  - [x] `Region` runs slot state to a fixed point over the graph. A join merges toward
        the shorter lived region, siblings merge into a `merged` region that answers for
        both, and a release is judged per path with the value's origin as the barrier,
        which is what separates "is used after" from "may be used after"
  - [x] `codegen/c.zig` hoists declarations and spells the graph as labels and gotos
  - [x] `Lower.endScope` is cleanup-on-every-path: `return`, `break` and `continue` each
        end the scopes they leave, and `nul_arena_destroy` tolerates NULL so an early
        `destroy` and the scope's own end never free twice
  - [ ] `for x in y` waits on slices, which is what there is to iterate
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
- [ ] `usize` and `isize` have no width, so only what every width shares is checked: a
      known negative value cannot enter either unsigned one. Giving them a width makes
      `usize` and `u64` the same type, which is a decision about the language rather
      than a fix, and it wants a target concept first
- [x] Constant division by zero is reported where it is written (`E0021`), and comptime
      folds that leave `i128` report rather than wrap (`E0022`)
- [ ] Does `create` zero its memory? The C backend hands back whatever `malloc` gave, so
      an unset field is garbage today. Decide the semantics, then enforce them

## Memory model and checker

- [ ] **Concurrency.** Zero mentions across `README.md`, `spec.md` and `memory_model.md`.
      Arenas plus threads may constrain `Arena` itself, so sketch it before the stdlib
- [x] The branch cases are `test/fail` files: a release inside one arm with the use after
      the join (27), and a pointer that means different arenas on different paths (31, 32)
- [x] `arena.destroy()` followed by `arena.create()` is caught (`checkArenaAlive`), with
      per-path wording when the destroy sits in a branch. `reset` still leaves the handle
      alive, as it should
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

- [x] Parse errors carry permanent codes: `Ast.Error.Tag` owns `E01xx`, semantic errors
      own `E00xx`
- [ ] `nul explain E0007`, now that codes are stable

## Tooling

- [x] File tests run in `zig build test`: `test/pass` must check clean, `test/fail` must
      match its `.expected` snapshot, and `zig build test-update` rewrites the snapshots
- [ ] `nul dump <file>` for token, AST and NIR inspection, dropped when `main.zig` went
- [ ] `nul build` could invoke the C compiler rather than printing a path

## Documentation

- [ ] `README.md`'s example uses `!*Node` and does not compile
- [ ] `spec.md` covers signature sufficiency and comptime; everything else the language
      has settled still lives in commit messages and in this file instead
- [ ] Write down the direction: phase-structured programs, Go-shaped surface, systems
      semantics. It is the reason to choose Nul and it is stated nowhere

## Demos

- [ ] An arena-per-request server. The shortest path from "interesting research" to "I
      want to use this", and it stresses the model exactly where its domain lives
