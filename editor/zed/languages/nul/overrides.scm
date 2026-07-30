; The scopes `config.toml` names in `not_in`. Inside one of these, Zed stops
; autoclosing and treats the text as prose rather than code.

[
  (comment)
  (doc_comment)
  (file_doc_comment)
] @comment

(string_literal) @string
