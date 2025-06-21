-- @thanks to @stevearc and Aerial.nvim for those quiers as they are lirteral
-- copy paste. I found that "locals" make it very hard when dealing
-- with javascript and typescript
-- I need to do more queries but needs to learn it first :)
local M = {}

M.typescript = [[
(function_signature
  name: (identifier) @name
  (#set! "kind" "Function")) @symbol

(function_declaration
  name: (identifier) @name
  (#set! "kind" "Function")) @symbol

(generator_function_declaration
  name: (identifier) @name
  (#set! "kind" "Function")) @symbol

(interface_declaration
  name: (type_identifier) @name
  (#set! "kind" "Interface")) @symbol

(class_declaration
  name: (type_identifier) @name
  (#set! "kind" "Class")) @symbol

(method_definition
  name: (property_identifier) @name
  (#set! "kind" "Method")) @symbol

(public_field_definition
  name: (property_identifier) @name
  value: (arrow_function)
  (#set! "kind" "Method")) @symbol

(type_alias_declaration
  name: (type_identifier) @name
  (#set! "kind" "Variable")) @symbol

(lexical_declaration
  (variable_declarator
    name: (identifier) @name
    value: (_) @var_type) @symbol
  (#set! "kind" "Variable")) @start

; describe("Unit test")
(call_expression
  function: (identifier) @method @name
  (#any-of? @method "describe" "it" "test" "afterAll" "afterEach" "beforeAll" "beforeEach")
  arguments: (arguments
    (string
      (string_fragment) @name @string))?
  (#set! "kind" "Function")) @symbol @selection

; test.skip("this test")
(call_expression
  function: (member_expression
    object: (identifier) @method
    (#any-of? @method "describe" "it" "test")
    property: (property_identifier) @modifier
    (#any-of? @modifier "skip" "todo")) @name
  arguments: (arguments
    (string
      (string_fragment) @name @string))?
  (#set! "kind" "Function")) @symbol @selection

; describe.each([])("Test suite")
(call_expression
  function: (call_expression
    function: (member_expression
      object: (identifier) @method
      (#any-of? @method "describe" "it" "test")
      property: (property_identifier) @modifier
      (#any-of? @modifier "each")) @name)
  arguments: (arguments
    (string
      (string_fragment) @name @string))?
  (#set! "kind" "Function")) @symbol @selection
]]

M.javascript = [[
(class_declaration
  name: (identifier) @name
  (#set! "kind" "Class")) @symbol

(function_declaration
  name: (identifier) @name
  (#set! "kind" "Function")) @symbol

(generator_function_declaration
  name: (identifier) @name
  (#set! "kind" "Function")) @symbol

(method_definition
  name: (property_identifier) @name
  (#set! "kind" "Method")) @symbol

(field_definition
  property: (property_identifier) @name
  value: (arrow_function)
  (#set! "kind" "Method")) @symbol

; const fn = () => {}
(lexical_declaration
  (variable_declarator
    name: (identifier) @name
    value: [
      (arrow_function)
      (function_expression)
      (generator_function)
    ] @symbol)
  (#set! "kind" "Function")) @start

; describe("Unit test")
(call_expression
  function: (identifier) @method @name
  (#any-of? @method "describe" "it" "test" "afterAll" "afterEach" "beforeAll" "beforeEach")
  arguments: (arguments
    (string
      (string_fragment) @name @string))?
  (#set! "kind" "Function")) @symbol

; test.skip("this test")
(call_expression
  function: (member_expression
    object: (identifier) @method
    (#any-of? @method "describe" "it" "test")
    property: (property_identifier) @modifier
    (#any-of? @modifier "skip" "todo")) @name
  arguments: (arguments
    (string
      (string_fragment) @name @string))?
  (#set! "kind" "Function")) @symbol

; describe.each([])("Test suite")
(call_expression
  function: (call_expression
    function: (member_expression
      object: (identifier) @method
      (#any-of? @method "describe" "it" "test")
      property: (property_identifier) @modifier
      (#any-of? @modifier "each")) @name)
  arguments: (arguments
    (string
      (string_fragment) @name @string))?
  (#set! "kind" "Function")) @symbol
]]

M.make = [[
  (rule
    (targets
    (word) @name)
    (#not-any-of? @name
      ".ONESHELL"
      ".PHONY"
     )
  (#set! "kind" "Interface")) @symbol
]]

-- Markdown query
M.markdown = [[
(atx_heading
  [
    (atx_h1_marker)
    (atx_h2_marker)
    (atx_h3_marker)
    (atx_h4_marker)
    (atx_h5_marker)
    (atx_h6_marker)
  ] @level
  heading_content: (_) @name
  (#set! "kind" "Interface")) @symbol

(setext_heading
  heading_content: (_) @name
  (#set! "kind" "Interface")
  [
    (setext_h1_underline)
    (setext_h2_underline)
  ] @level) @symbol
]]

-- Vimdoc query
M.vimdoc = [[
(h1
  (word)+ @name @start
  (tag)
  (#set! "kind" "Interface")) @symbol

(h2
  (word)+ @name @start
  (tag)
  (#set! "kind" "Interface")) @symbol

(tag
  text: (word) @name
  (#set! "kind" "Interface")) @symbol
]]

M.json = [[
; Capture pairs where the value is an object or array (structural view)
(pair
  key: (string) @name
  value: [(object) (array)] @value
  (#set! "kind" "Object") ; Kind for structural elements
) @symbol

; Capture primitive pairs ONLY at the top level (direct children of root object)
(document
  (object
    (pair
      key: (string) @name
      value: [(string) (number) (true) (false) (null)] @value
      (#set! "kind" "Property") ; Kind for top-level primitive properties
    ) @symbol
  )
)
]]

M.toml = [[
(table
  [
    (bare_key)
    (dotted_key)
    (quoted_key)
  ] @name
  (#set! "kind" "Class")
) @symbol

(table_array_element
  [
    (bare_key)
    (dotted_key)
    (quoted_key)
  ] @name
  (#set! "kind" "Enum")
) @symbol
]]

-- Get the appropriate query for a filetype
function M.get_query_for_filetype(filetype)
  return M[filetype]
end

return M
