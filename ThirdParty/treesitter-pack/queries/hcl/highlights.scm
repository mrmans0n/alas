(comment) @comment

(attribute
  (identifier) @property)

(block
  (identifier) @type)

(function_call
  (identifier) @function)

[
  "for"
  "in"
  "if"
  "else"
  "endif"
  "endfor"
] @keyword

[
  "true"
  "false"
] @constant

(null_lit) @constant
(numeric_lit) @number

[
  (string_lit)
  (template_literal)
] @string

[
  (quoted_template_start)
  (quoted_template_end)
  (heredoc_start)
  (heredoc_identifier)
] @punctuation

[
  "="
  "=>"
  "=="
  "!="
  "<"
  ">"
  "<="
  ">="
  "+"
  "-"
  "*"
  "/"
  "%"
  "&&"
  "||"
  "!"
] @operator

[
  "{"
  "}"
  "["
  "]"
  "("
  ")"
  ","
  "."
  ":"
  "?"
] @punctuation
