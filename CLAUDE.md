# CLAUDE.md

Code style, safety, performance, and naming rules live in [AGENTS.md](AGENTS.md).
Read that first and follow it for anything inside a source file. This file covers
everything outside the code: what to run, what to commit, and how a release
happens.

## Layout

```
compiler/    the compiler, importable as the `compiler` module
tools/zol/   the binary: argv, dispatch, exit codes
lib/std/     the standard library, shipped as source beside the binary
test/        file tests, one directory per kind
```

## Commands

Zig 0.16.0 or newer, as `build.zig.zon` states.

```
zig build                                     build ./zig-out/bin/zol
zig build test                                unit tests and file tests
zig build test-update                         rewrite what the file tests expect
zig build release                             cross-compile a tree per target
zig fmt --check build.zig compiler tools test what CI checks
```

`test-update` accepts whatever the compiler currently prints. After running it,
read the diff. A golden that changed for a reason you cannot name is a
regression you just recorded as expected.

## After every change

1. `zig build test`. It takes under a second, so there is no reason to skip it.
2. `zig fmt`.
3. Add one line under `## [Unreleased]` in `CHANGELOG.md`, **only if a user
   would notice**: the language, a diagnostic code, the standard library, or the
   command line. Refactors, internals, tests, and CI changes get no entry.
4. Commit, push, and wait for CI.

## Commit messages

```
area: imperative summary
```

- Lowercase after the colon, imperative mood, no trailing full stop.
- Subject at most 50 characters so `git log --oneline` never wraps. Hard limit 72.
- Blank line, then a body wrapped at 72 explaining **why**. The diff already says
  what changed.
- One logical change per commit.
- No trailers of any kind. No `Co-Authored-By`, no `Generated with`, no tool or
  assistant attribution. A commit is authored by whoever committed it, and the
  message is for the next reader of `git blame`, not a record of who typed it.

```
check: remove the two-arena rule

The rule refused a second Arena parameter, but nothing else in the
compiler enforced the memory model, so it rejected valid programs while
the rules it belonged to went unchecked. The region checker reimposes it
along with the rest.
```

Conventional Commits (`feat:`, `fix:`, `chore:`) is not used here. It exists to
feed changelog generators, and this changelog is written by hand, so the prefix
would cost the area name and buy nothing.

## Releasing

Versions are `0.MINOR.PATCH`. Before 1.0 a minor release may change the language
in ways that break programs that used to compile, and a patch release only fixes.

**When.** `## [Unreleased]` is the trigger. Entries someone could act on means a
minor. A shipped release that is broken means a patch. Empty means there is
nothing to release, so do not cut one on a schedule.

**How.**

1. Move `[Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD` and add the two link
   definitions at the foot of the file.
2. Set `.version` in `build.zig.zon` to `X.Y.Z`.
3. `zig build release`, as a local smoke test.
4. Commit `release: X.Y.Z`, push `main`, and wait for CI to pass.
5. `git tag -a X.Y.Z -m "Zol X.Y.Z"`.
6. `git push origin X.Y.Z`, on its own.
7. Set `.version` to the next minor, so later builds report `X.Y+1.0-dev.N+hash`.

Three rules, each of which has already cost a release:

- Tag only a commit CI has passed.
- Push the tag by itself. A branch and a tag in one `git push` loses the tag
  event, and the release workflow never runs.
- Never move a published tag.

The tag fires `.github/workflows/release.yml`, which builds every target,
archives them with checksums, and takes the release notes from the `[X.Y.Z]`
section of `CHANGELOG.md`. `build.zig` refuses to build when the tag and the
manifest version disagree, so a mistagged release stops before it publishes.

## Versions

`build.zig.zon` holds the next, unreleased version. A build standing on the
matching tag reports it bare, and every other build reports something like
`0.2.0-dev.47+7f3a91c9a`, so a bug report names one commit rather than a branch.
