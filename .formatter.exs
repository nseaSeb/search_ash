spark_locals_without_parens = [
  action: 1,
  default_language: 1,
  fields: 1,
  index: 1,
  index_name: 1,
  label_field: 1,
  language_attribute: 1,
  on_destroy: 1,
  prefix?: 1,
  rank?: 1,
  search_text_attribute: 1,
  source_type: 1,
  state: 1,
  visible_states: 1
]

[
  import_deps: [:ash, :ash_postgres],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: spark_locals_without_parens,
  export: [locals_without_parens: spark_locals_without_parens]
]
