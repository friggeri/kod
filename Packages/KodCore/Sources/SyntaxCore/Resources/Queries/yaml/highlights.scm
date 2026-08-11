(boolean_scalar) @boolean

(null_scalar) @constant.builtin

[
  (integer_scalar)
  (float_scalar)
] @number

(timestamp_scalar) @constant

(comment) @comment

[
  (anchor_name)
  (alias_name)
] @label

(tag) @type

[
  (yaml_directive)
  (tag_directive)
  (reserved_directive)
] @attribute

; Capture keys and string values through their structural context so a key is
; never also emitted as a generic string capture.
(block_mapping_pair
  key: (flow_node
    [
      (double_quote_scalar)
      (single_quote_scalar)
    ] @property))

(block_mapping_pair
  key: (flow_node
    (plain_scalar
      (string_scalar) @property)))

(flow_pair
  key: (flow_node
    [
      (double_quote_scalar)
      (single_quote_scalar)
    ] @property))

(flow_pair
  key: (flow_node
    (plain_scalar
      (string_scalar) @property)))

(flow_mapping
  (flow_node
    (plain_scalar
      (string_scalar) @property)))

(block_mapping_pair
  value: (flow_node
    [
      (double_quote_scalar)
      (single_quote_scalar)
    ] @string))

(block_mapping_pair
  value: (flow_node
    (plain_scalar
      (string_scalar) @string)))

(flow_pair
  value: (flow_node
    [
      (double_quote_scalar)
      (single_quote_scalar)
    ] @string))

(flow_pair
  value: (flow_node
    (plain_scalar
      (string_scalar) @string)))

(block_sequence_item
  (flow_node
    [
      (double_quote_scalar)
      (single_quote_scalar)
    ] @string))

(block_sequence_item
  (flow_node
    (plain_scalar
      (string_scalar) @string)))

(flow_sequence
  (flow_node
    [
      (double_quote_scalar)
      (single_quote_scalar)
    ] @string))

(flow_sequence
  (flow_node
    (plain_scalar
      (string_scalar) @string)))

(document
  (flow_node
    [
      (double_quote_scalar)
      (single_quote_scalar)
    ] @string))

(document
  (flow_node
    (plain_scalar
      (string_scalar) @string)))

(block_scalar) @string

[
  ","
  "-"
  ":"
  ">"
  "?"
  "|"
] @punctuation.delimiter

[
  "["
  "]"
  "{"
  "}"
] @punctuation.bracket

[
  "*"
  "&"
  "---"
  "..."
] @punctuation.special
