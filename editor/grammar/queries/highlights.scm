; Syntax highlighting for Nul.
;
; Later patterns win, so this file reads general to specific: every name starts
; as a variable and the rules below take it back.
;
; Two things carry colour here. Shape, where the tree already knows what a name
; is, and convention, where it does not. Nul spells types with a capital and
; everything else without, which is what the `#match?` rules near the end rely
; on: a name reached through a dotted path has no node to tell it apart from
; the module it came through.

; Names

(identifier) @variable

((identifier) @variable.builtin
  (#eq? @variable.builtin "_"))

(parameter
  name: (identifier) @variable.parameter)

(capture
  name: (identifier) @variable.parameter)

(type_parameter
  (identifier) @type.parameter)

; Fields, of a declaration and of a literal, and the ones read back off a value

(field_declaration
  name: (identifier) @variable.member)

(field_initializer
  name: (identifier) @variable.member)

(field_expression
  field: (identifier) @property)

; Types, wherever the tree says so

(struct_declaration
  name: (identifier) @type)

(type_declaration
  name: (identifier) @type)

(parameter
  type: (identifier) @type)

(field_declaration
  type: (identifier) @type)

(variable_declaration
  type: (identifier) @type)

(function_declaration
  return_type: (identifier) @type)

(pointer_type
  (identifier) @type)

(optional_type
  (identifier) @type)

(error_union_type
  (identifier) @type)

(generic_type
  name: (identifier) @type)

(type_arguments
  (identifier) @type)

; A dotted path is modules down to one name at the end. Only the convention
; below can tell which is which, so start them all as modules.

(qualified_name
  (identifier) @module)

(use_declaration
  path: (identifier) @module)

; Functions

(function_declaration
  name: (identifier) @function)

(call_expression
  function: (identifier) @function.call)

(call_expression
  function: (field_expression
    field: (identifier) @function.method.call))

(call_expression
  function: (instance_expression
    function: (identifier) @function.call))

(call_expression
  function: (instance_expression
    function: (field_expression
      field: (identifier) @function.method.call)))

; A top-level binding is a value the compiler works out, so it reads as one.

(source_file
  (variable_declaration
    name: (identifier) @constant))

; Convention, where shape ran out

((identifier) @type
  (#match? @type "^[A-Z]"))

((identifier) @type.builtin
  (#any-of? @type.builtin
    "bool" "i8" "i16" "i32" "i64" "u8" "u16" "u32" "u64" "isize" "usize" "f32"
    "f64" "str"))

; Keywords

[
  "let"
  "var"
  "defer"
] @keyword

[
  "struct"
  "type"
] @keyword.type

"fn" @keyword.function

"use" @keyword.import

"pub" @keyword.modifier

; `*var T` is the pointer that writes, so the keyword modifies a type here
; rather than introducing a binding.
(pointer_type
  "var" @keyword.modifier)

"return" @keyword.return

[
  "if"
  "else"
] @keyword.conditional

[
  "while"
  "break"
  "continue"
] @keyword.repeat

[
  "try"
  "catch"
] @keyword.exception

[
  "and"
  "or"
  "orelse"
] @keyword.operator

(error_value
  "error" @keyword.exception)

; Literals

((string_literal) @string
  (#set! "priority" 95))

(escape_sequence) @string.escape

(number_literal) @number

(boolean_literal) @boolean

(null_literal) @constant.builtin

(error_value
  name: (identifier) @constant)

; Operators and punctuation

[
  "="
  "=="
  "!="
  "<"
  "<="
  ">"
  ">="
  "+"
  "-"
  "*"
  "/"
  "%"
  "!"
  "&"
  "?"
] @operator

[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
] @punctuation.bracket

(capture
  "|" @punctuation.bracket)

[
  ";"
  "."
  ","
  ":"
] @punctuation.delimiter

; Comments

(comment) @comment

[
  (doc_comment)
  (file_doc_comment)
] @comment.documentation
