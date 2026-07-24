defmodule SearchAsh.Test.Synonyms do
  @moduledoc false
  # The callback (`{module, function}`) form of `global_index`'s `synonyms` option: given a
  # language, return that language's `%{key => [phrase, ...]}` map.
  def for_language(:fr), do: %{"bl" => ["bon de livraison"]}
  def for_language(_other), do: %{}
end
