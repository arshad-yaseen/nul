; Text objects, in the Neovim dialect (`.outer` / `.inner`).
; Zed reads its own dialect from editors/zed/languages/nul/textobjects.scm.

(function_declaration) @function.outer

(function_declaration
  body: (block
    "{"
    (_)* @function.inner
    "}"))

; An `= expr` body has no braces, so the expression is the whole inside.
(function_declaration
  "="
  body: (_) @function.inner)

(struct_declaration) @class.outer

(struct_declaration
  body: (struct_body
    "{"
    (_)* @class.inner
    "}"))

(parameter) @parameter.outer

(parameter
  type: (_) @parameter.inner)

(field_declaration) @parameter.outer

(if_statement) @conditional.outer

(if_statement
  consequence: (block
    "{"
    (_)* @conditional.inner
    "}"))

(while_statement) @loop.outer

(while_statement
  body: (block
    "{"
    (_)* @loop.inner
    "}"))

(call_expression) @call.outer

(call_expression
  arguments: (arguments
    "("
    (_)* @call.inner
    ")"))

(block) @block.outer

(block
  "{"
  (_)* @block.inner
  "}")

[
  (comment)
  (doc_comment)
  (file_doc_comment)
] @comment.outer
