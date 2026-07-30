; Zed's dialect: `.around` takes the whole thing, `.inside` takes what the
; braces hold.

(function_declaration
  body: (block
    "{"
    (_)* @function.inside
    "}")) @function.around

(struct_declaration
  body: (struct_body
    "{"
    (_)* @class.inside
    "}")) @class.around

(if_statement
  consequence: (block
    "{"
    (_)* @conditional.inside
    "}")) @conditional.around

(while_statement
  body: (block
    "{"
    (_)* @loop.inside
    "}")) @loop.around

[
  (comment)
  (doc_comment)
  (file_doc_comment)
] @comment.around
