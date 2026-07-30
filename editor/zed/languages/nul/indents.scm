; Zed's dialect: the node that indents is `@indent`, and the token that closes
; it back out is `@end`.

(block
  "}" @end) @indent

(struct_body
  "}" @end) @indent

(struct_literal
  "}" @end) @indent

(parameters
  ")" @end) @indent

(arguments
  ")" @end) @indent

(type_parameters
  "]" @end) @indent

(type_arguments
  "]" @end) @indent
