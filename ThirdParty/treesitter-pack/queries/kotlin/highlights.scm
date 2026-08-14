; Highlight query for tree-sitter-grammars/tree-sitter-kotlin ("kotlin-ng").
;
; Written against this grammar directly (node-types.json + grammar.js) rather
; than ported from fwcd/tree-sitter-kotlin — the two grammars use different
; node names (e.g. this one has no `simple_identifier`) and a query for one
; does not compile against the other.

; Comments
(line_comment) @comment
(block_comment) @comment

; Literals
(string_literal) @string
(multiline_string_literal) @string
(character_literal) @string
(escape_sequence) @string.escape
(number_literal) @number
(float_literal) @number

((identifier) @constant.builtin
  (#match? @constant.builtin "^(true|false|null)$"))

(this_expression) @variable.builtin
(super_expression) @variable.builtin

(label) @label
(shebang) @comment

; Annotations
(annotation) @attribute
(use_site_target) @attribute

; Declarations
(class_declaration name: (identifier) @type)
(object_declaration name: (identifier) @type)
(companion_object name: (identifier) @type)
(type_alias type: (identifier) @type.definition)
(function_declaration name: (identifier) @function)
(secondary_constructor "constructor" @keyword)

; Types
(user_type (identifier) @type)
(type_parameter (identifier) @type)
(type_constraint (identifier) @type)
"dynamic" @type.builtin

; Calls
(call_expression (identifier) @function.call)
(call_expression (navigation_expression (identifier) @function.call .))
(constructor_invocation (user_type (identifier) @type))

; Members / parameters
(navigation_expression (identifier) @property .)
(parameter (identifier) @variable.parameter)
(class_parameter (identifier) @variable.parameter)
(getter "get" @keyword)
(setter "set" @keyword)

; Imports / packages
(import "import" @keyword)
(package_header "package" @keyword)
(qualified_identifier (identifier) @namespace)

; Keywords — declarations
[
  "class"
  "interface"
  "object"
  "fun"
  "val"
  "var"
  "typealias"
  "constructor"
  "init"
  "companion"
] @keyword

; Keywords — modifiers
[
  "abstract" "final" "open"
  "override" "lateinit"
  "public" "private" "protected" "internal"
  "enum" "sealed" "annotation" "data" "inner" "value"
  "tailrec" "operator" "infix" "inline" "external" "suspend"
  "vararg" "noinline" "crossinline"
  "expect" "actual"
  "in" "out"
] @keyword

; property_modifier ("const") and reification_modifier ("reified") are each
; defined as a bare string literal with no other structure, so tree-sitter
; collapses them into a named leaf instead of a separately addressable
; anonymous token — the node must be matched, not the literal text.
(property_modifier) @keyword
(reification_modifier) @keyword

; Keywords — control flow
;
; `continue`/`break` are omitted: continue_expression/break_expression are
; defined in the grammar but never referenced by any reachable rule, so the
; compiler drops them — they are not part of this grammar's vocabulary.
[
  "if" "else"
  "when"
  "for" "while" "do"
  "try" "catch" "finally"
  "throw"
  "return" "return@"
] @keyword.control

; Keywords — other
[
  "package" "import" "as" "as?"
  "by" "is" "!is"
  "this" "super"
  "get" "set"
] @keyword

; Punctuation
[ "(" ")" "[" "]" "{" "}" ] @punctuation.bracket
[ "," ";" ":" "." ] @punctuation.delimiter
[ "?" "?." ] @punctuation.special

; Operators
[
  "+" "-" "*" "/" "%"
  "=" "+=" "-=" "*=" "/=" "%="
  "==" "!=" "===" "!=="
  "<" ">" "<=" ">="
  "&&" "||" "!" "!!"
  "++" "--"
  ".." "..<"
  "->"
  "::"
  "?:"
] @operator
