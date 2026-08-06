# Zol

**As simple as Go, as bare as C. Memory safe at compile time, with nothing to annotate.**

A research project into systems programming without a runtime. Not usable, and not
intended for use any time soon.

No garbage collector. No hidden allocations. No lifetime annotations.

> How much of memory safety can be proven from the allocator you were already passing down, without a borrow checker to learn?

## Builds

Every release, and every commit that reaches `main`, is cross-compiled for macOS,
Linux, and Windows and published on the [releases page][releases]. Numbered
releases are the only ones that are supported. `dev` is the tip of `main`, and
the next commit overwrites it.

Each set ships `SHA256SUMS` and an `index.json` naming the version, the commit,
and every archive. Two URLs never move:

```
https://github.com/arshad-yaseen/zol/releases/latest/download/index.json
https://github.com/arshad-yaseen/zol/releases/download/dev/index.json
```

Archives carry a build provenance attestation, so a download can be traced back
to the commit and the workflow run that produced it:

```console
$ gh attestation verify zol-*.tar.xz --repo arshad-yaseen/zol
```

[releases]: https://github.com/arshad-yaseen/zol/releases

## Status

Design first, implementation second. The front end is real: parsing with recovery,
modules, generics instantiated on demand, and a typed control flow graph. It ends
there: `zol` checks a program and prints its IR, and nothing runs.

Nothing about memory is checked either, and the first sketch of an allocator has
been taken back out while the model is redesigned. There is no standard library
right now. Read this as a set of ideas, not a toolchain.
