//! The Nul compiler. Source bytes in, a typed control-flow graph or
//! diagnostics out. Read in pipeline order: `Source`, `Token`, `Tokenizer`,
//! `AST`, `Parse`, then `Pool`, `Module`, `Compilation`, `Check`, `IR`.

pub const AST = @import("AST.zig");
pub const Compilation = @import("Compilation.zig");
pub const Diagnostic = @import("Diagnostic.zig");
pub const IR = @import("IR.zig");
pub const Module = @import("Module.zig");
pub const Pool = @import("Pool.zig");
pub const Source = @import("Source.zig");
pub const Token = @import("Token.zig");
pub const Tokenizer = @import("Tokenizer.zig");
pub const dump = @import("util/dump.zig").dump;

test {
    @import("std").testing.refAllDecls(@This());
}
