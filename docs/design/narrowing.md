# Narrowing

Inside a branch that has established which member a union holds, the
tested name is that member: no cast, no unwrap, no second name.

```phi
fn use_it(xs: List) {
    let r = find(xs, 7)                 // r : u32 | none

    if r is u32 {
        report(r)                       // r : u32
    } else {
        report_missing()               // r : none, the complement narrows too
    }
}
```

This is the half of the union design that makes the other half usable,
and its rules exist to keep the proof sound and the names few. A narrowed
name is the member everywhere: its fields, its methods, and its uses as
an argument all see the member type, so
`if shape is Circle { shape.area() }` calls Circle's method.

## What narrows

Narrowing applies to `let` bindings and parameters, never to `var`. Those
cannot change between the test and the use, so the soundness argument is
one sentence: what cannot mutate cannot be invalidated. There is no
invalidation analysis, and nothing quietly cancels a narrowing at a call
or inside a loop. A `var` is bound to a `let` before testing, one visible
line that documents the moment the value became fixed:

```phi
var slot: u32 | none = poll()
let held = slot                         // fixed here
if held is u32 {
    consume(held)                       // held : u32, whatever slot does
}
```

`is` never binds: it re-types the name that already exists, in the branch
that proved the member, in the branch that denied it, across `and`, and
past a branch that leaves. Where there is no name to re-type, the program
makes one with `let`. One name per value, from declaration to use.

```phi
if r is u32 and r > 0 { use(r) }        // the proof holds across and

if r is not u32 { return 0 }
report(r)                               // r : u32 for the rest of the body
```

Refused: narrowing `var` with invalidation rules, where the analysis is
subtle, the failures are quiet, and the rules leak into every future way
to mutate. Binding forms such as `if (x is T t)`, a second name for a
value that has one, and a scope question in every branch.

## or

`e or f` is the first member of `e`, or else `f`. That one operator is
the four verbs of optionals and errors:

```phi
let port = config.port or 8080          // substitute
let cfg = load(id) or return            // propagate, unchanged
let job = queue.take() or break         // leave a loop
let cfg = load(id) or e {               // bind the rest and handle it
    log_failure(e)
    return 1
}
```

On a union of more than two, the split is first member against everything
else, so a failure set stays whole in the handler: off
`Config | FileError | Timeout`, the `e` above binds
`FileError | Timeout`. On a `bool`, the same rule is logical or, because
`true` is the first member, so the boolean operator is a special case
rather than a sibling.

An `or` that ends in `return`, `break`, or `continue` may stand as a
statement, and what it proved holds for the rest of the block, which
makes the guard the cheap spelling of an early exit:

```phi
fn get(self: Value, key: u32) u32 | none {
    self is Object or return none
    return self.lookup(key)             // self : Object from here down
}
```

Refused: `try` or `?` as propagation sugar, control flow that does not
look like control flow. Distinct operators for optionals and errors, a
distinction the type system does not have. A `??` beside a boolean `or`,
two operators whose meanings converge the moment `bool` is a union.

## match

`match` is the n-way `is`. An arm labels one member, several with `|`, or
an alias, which covers the members it names, and inside the arm the
scrutinee is what the label proved:

```phi
fn area(shape: Shape) f64 {
    return match shape {
        Circle => shape.r * shape.r * 3.14159
        Rect => shape.w * shape.h
        Line => 0.0
    }
}
```

No arm binds a name, the rule `is` already follows: a scrutinee with no
name is bound with `let` first. Exhaustiveness is counting: every member
covered exactly once, an unhandled member refused, an arm that cannot run
refused. Adding a member to a union breaks every match over it, on
purpose, and an alias arm keeps a failure set one name from signature to
handler:

```phi
fn report(id: u32) u8 {
    let cfg = load(id) or e {
        match e {                       // e : LoadError, three arms cover it
            FileError => log_code(e.code)
            BadSyntax => log_line(e.line)
            Timeout => log_slow()
        }
        return 1
    }
    return use(cfg)
}
```

`else` covers what is left, and is the rest as a type rather than a blind
default: one member left stands bare, several stay a union, so the rest
can be handed on whole. Arms that leave narrow what follows the match,
the way any branch that leaves does:

```phi
fn code(reply: Reply) u8 {
    return match reply {
        Config => 0
        else => classify(reply)         // reply : Timeout | NotFound
    }
}

fn settle(reply: Reply) Config {
    match reply {
        Timeout | NotFound => return Config.fallback()
        Config => {}
    }
    return reply                        // reply : Config
}
```

Counting keeps the checker small and its messages in members, not pattern
shapes, and structure inside a member is reached the way it always is, by
narrowing and then field access, which is most of what patterns would
buy.

Refused: full pattern matching, nested patterns with ordered first-match
semantics and binding forms, for reach the narrowing rules already
provide. Binding arms such as `Member v =>`, the same refusal `is` makes.
An `else` that types as the whole union, which would launder the members
the arms already handled back into scope.
