; Alas-maintained: tree-sitter-kotlin-ng ships no tags query.
; Only top-level and class-body properties are tagged, never locals.

(class_declaration
  "interface"
  name: (identifier) @name) @definition.interface

(class_declaration
  "class"
  name: (identifier) @name) @definition.class

(object_declaration
  name: (identifier) @name) @definition.class

(function_declaration
  name: (identifier) @name) @definition.function

(source_file
  (property_declaration
    (variable_declaration
      (identifier) @name)) @definition.property)

(class_body
  (property_declaration
    (variable_declaration
      (identifier) @name)) @definition.property)
