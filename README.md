# Nul

A research project exploring compile time memory safety for a systems language with no
runtime. Not usable, and not intended for use any time soon.

No garbage collector. No hidden allocations. No lifetime annotations.

The question the project is asking: how much of memory safety can be proven from the
allocator you were already passing down, without a borrow checker to learn?

## Status

Design first, implementation second. The compiler is incomplete, the surface will
change, and nothing here is stable. Read it as a set of ideas, not a toolchain.
