; Scopes and the names they bind. Editors use this to tell one `value` from
; another when two functions both have one, which is what makes rename and
; highlight-occurrences land on the right places.

; Scopes

(function_declaration) @local.scope

(struct_declaration) @local.scope

(block) @local.scope

; Definitions

(function_declaration
  name: (identifier) @local.definition.function)

(struct_declaration
  name: (identifier) @local.definition.type)

(type_declaration
  name: (identifier) @local.definition.type)

(type_parameter
  (identifier) @local.definition.type)

(parameter
  name: (identifier) @local.definition.parameter)

; A capture binds for the arm it introduces, the same as a parameter does.
(capture
  name: (identifier) @local.definition.parameter)

(variable_declaration
  name: (identifier) @local.definition.var)

(field_declaration
  name: (identifier) @local.definition.field)

; References

(identifier) @local.reference
