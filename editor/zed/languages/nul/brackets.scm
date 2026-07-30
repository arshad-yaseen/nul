("(" @open ")" @close)

("[" @open "]" @close)

("{" @open "}" @close)

("\"" @open "\"" @close)

; A capture is delimited by a pair of pipes, so they match like a bracket.
(capture
  "|" @open
  "|" @close)
