# Used by "mix format". import_deps pulls in the DSL locals-without-parens exported by
# search_ash / ash / ash_postgres, so `search do fields [...] end` and the Ash resource
# DSL format without stray parentheses.
[
  import_deps: [:search_ash, :ash, :ash_postgres],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}", "*.exs"]
]
