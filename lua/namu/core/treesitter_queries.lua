local M = {}

-- TypeScript/JavaScript query
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

-- JavaScript can use the TypeScript query for now
M.javascript = M.typescript

-- Get the appropriate query for a filetype
function M.get_query_for_filetype(filetype)
  return M[filetype]
end

return M
