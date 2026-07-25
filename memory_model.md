# Nul Memory Model

## The contract

Every Nul program is memory safe at compile time. There is no garbage collector, no runtime, and no compiler inserted cleanup code. The programmer never writes lifetime annotations, never learns ownership or borrowing vocabulary, and never fights an analysis they cannot see. What the programmer writes is what executes, and the compiler's only job is to reject programs that would use memory after it dies.

## Rule one, everything is a value

Assignment and argument passing behave as if the value were copied. There is no aliasing in the semantics of the language, so there is no way for two names to disagree about the state of one object. The compiler is free to turn a copy into a move or a borrow whenever the difference cannot be observed, which is where the performance comes from, but this optimization is invisible and unobservable rather than hidden. Nothing a programmer can measure changes. This rule is what makes the rest of the model tractable, because it means the only aliasing in a program is aliasing the programmer wrote down as a pointer.

## Rule two, memory comes from arenas

There is no global heap and no implicit allocator. Memory is obtained from an arena, which is an explicit object the programmer creates, chooses the backing storage for, and passes down to any function that needs to allocate. Arenas may be nested, so an arena can draw its memory from a parent arena, and a program may hold several arenas at once for different purposes, such as one for long lived data and one for scratch work that is discarded each iteration. Every allocated value belongs to exactly one arena, and its lifetime is the lifetime of that arena. Nothing is freed individually. When an arena dies, everything in it dies at the same instant, in one bulk operation.

The important design consequence is that the arena parameter a function already takes is doing double duty. It is both the allocator and the name of a lifetime. The programmer writes it because they need somewhere to allocate from, and the compiler reads it as the region tag it needs for checking. This is why the model costs zero annotations. The information the compiler needs is information the programmer was already writing for their own reasons.

## Rule three, pointers are free inside an arena and checked across arenas

Within a single arena, pointers behave exactly as they do in C. They can be stored in structs, returned from functions, held in collections, and used to build linked lists, trees, graphs, and intrusive data structures. There are no restrictions and no overhead. This is safe by construction rather than by analysis, because everything in one arena dies at one moment, so a pointer and the thing it points to cannot outlive each other. There is no ordering to get wrong.

The only pointer the compiler rejects is one that crosses arenas, meaning a pointer to memory in one arena stored inside something belonging to a different arena, or returned to a scope that does not own the arena the memory lives in. This is the only situation in which memory can die while a pointer to it survives, so it is the only situation the checker needs to police. Because every value carries the arena it came from, and arenas are named by the parameters already in scope, the check is local. It compares two names that both appear in the same function. It never requires whole program analysis, never crosses module boundaries, and never depends on what code elsewhere in the program happens to do.

Function parameters are exempt from all of this and may always borrow, both for reading and for mutation. A borrowed parameter cannot outlive the call that created it, so there is nothing to track. This means the common case of passing data into a function to read or modify it needs no thought at all.

## Cleanup is placed by the programmer and proven by the compiler

An arena dies at the end of its scope by default, and the programmer may also destroy or reset one explicitly at any earlier point, which matters for the scratch arena pattern where temporary allocations are discarded on every iteration of a loop. The compiler does not decide when memory should be freed and never inserts a free the programmer did not write. Instead it verifies the placement the programmer chose, proving that no value belonging to that arena is used after the point where the arena dies.

This distinction is the central design decision of the model and should not be softened. Inferring the correct cleanup point is a whole program property, it makes the answer depend on code in other files, and it produces errors that cannot be localized or explained. Verifying a stated cleanup point is local, decidable, and produces an error that names the value, names the arena, names the line where the arena died, and names the last line where the value was legitimately used. The programmer keeps the control they would have in C, and gains a proof they could not have in C.

## Relationships that outlive an arena

Some relationships in a program genuinely span different lifetimes, such as a long lived index that refers to objects created and destroyed over time. For these, the language directs the programmer to store an identity rather than an access path, meaning an integer index into a collection rather than a pointer into memory. An index is a plain number, so it is always safe to store anywhere, and reaching the data requires going back through the collection, which is visibly alive at the point of use. A stale index produces a wrong answer or a reported error, which is a logic bug the programmer can debug, rather than corrupted memory, which is not. The standard library provides a pool type with generational indices so that staleness itself can be detected.

For the rare case of data with many owners and individually determined lifetimes, the standard library provides a reference counted type. It is a library type rather than a language feature, it is written out at every use, and a program that does not import it contains none of its machinery. The core language inserts no code, ever.
