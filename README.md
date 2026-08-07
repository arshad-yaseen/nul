# Phi

**As simple as Go, as bare as C. Memory safe at compile time, with nothing to annotate.**

No garbage collector. No hidden allocations. No lifetime annotations.

> How much of memory safety can be proven from the allocator you were already passing down, without a borrow checker to learn?

A research project. `phi` checks a program and prints its IR. Nothing runs yet.

```console
$ phi check main.phi
$ phi ir main.phi
```

Builds for macOS, Linux, and Windows are on the [releases page][releases].

[releases]: https://github.com/arshad-yaseen/phi/releases
