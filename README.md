# Phi

**A systems programming language that proves memory safety at compile time, with no runtime and nothing to annotate.**

> How much of memory safety can be proven from the allocator you were already passing down, without a borrow checker to learn?

A research project. `phi` checks a program and prints its IR. Nothing runs yet.

```console
$ phi check main.phi
$ phi ir main.phi
```

## Speed

Phi also aims for extremely fast checking and compilation, in very little
memory. The same program in each language, structs through generics, unions,
and narrowing, checked single-threaded on an Apple M-series machine, Zig 0.16,
Rust 1.96:

|                                 | 267k lines     | 2.7M lines      |
| ------------------------------- | -------------- | --------------- |
| `phi check`                     | 59 ms · 48 MB  | 0.67 s · 426 MB |
| `zig build-obj -fno-emit-bin`   | 1.9 s · 425 MB | 58 s · 3.0 GB   |
| `cargo check`, from scratch     | 4.7 s · 1.1 GB | 64 s · 5.1 GB   |
| `cargo check`, one edit, cached | 1.8 s          | —               |

Zig has no check command, so its row is `build-obj` with emission off, and a
driver makes its lazy analysis reach every unit.

## Builds

Builds for macOS, Linux, and Windows are on the [releases page][releases].

[releases]: https://github.com/arshad-yaseen/phi/releases
