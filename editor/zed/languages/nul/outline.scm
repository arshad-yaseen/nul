; What the outline panel and the symbol picker show. `@item` is the row,
; `@name` is what you search for, and `@context` is the rest of the signature
; that makes the row readable on its own.

(struct_declaration
  "pub"? @context
  "struct" @context
  name: (identifier) @name) @item

(type_declaration
  "pub"? @context
  "type" @context
  name: (identifier) @name) @item

(function_declaration
  "pub"? @context
  "fn" @context
  name: (identifier) @name
  parameters: (parameters) @context) @item

(field_declaration
  name: (identifier) @name
  ":" @context
  type: (_) @context) @item

; Only top-level bindings. A `let` inside a body is not a file-level symbol.
(source_file
  (variable_declaration
    "pub"? @context
    kind: _ @context
    name: (identifier) @name) @item)

(use_declaration
  "use" @context
  path: (_) @name) @item
