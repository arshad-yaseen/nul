; Indentation, in the Neovim dialect (`@indent.begin` / `@indent.end`).
; Zed reads its own dialect from editors/zed/languages/nul/indents.scm.

[
  (struct_body)
  (block)
  (parameters)
  (arguments)
  (type_parameters)
  (type_arguments)
  (struct_literal)
] @indent.begin

[
  "}"
  ")"
  "]"
] @indent.branch

[
  "}"
  ")"
  "]"
] @indent.end

(comment) @indent.auto
