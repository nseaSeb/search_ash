spark_locals_without_parens = [
  action: 1,
  archived: 1,
  default_language: 1,
  default_limit: 1,
  excerpt_length: 1,
  extra_text: 1,
  extra_text: 2,
  fields: 1,
  fuzzy?: 1,
  fuzzy_threshold: 1,
  index: 1,
  index_attribute: 2,
  index_attribute: 3,
  index_name: 1,
  label_field: 1,
  language: 1,
  language_attribute: 1,
  load: 1,
  on_destroy: 1,
  prefix?: 1,
  rank?: 1,
  search_text_attribute: 1,
  source_type: 1,
  synonyms: 1,
  weight: 1,
  weight_values: 1,
  weights: 1
]

[
  import_deps: [:ash, :ash_postgres],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: spark_locals_without_parens,
  export: [locals_without_parens: spark_locals_without_parens]
]
