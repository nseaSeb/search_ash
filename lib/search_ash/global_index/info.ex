defmodule SearchAsh.GlobalIndex.Info do
  @moduledoc "Read a resource's `global_index do … end` configuration."
  alias Spark.Dsl.Extension

  @doc "Language used to stem the query when the language argument is omitted."
  def default_language(resource),
    do: Extension.get_opt(resource, [:global_index], :default_language, :fr)

  @doc "Attribute holding the pre-stemmed tokens."
  def search_text_attribute(resource),
    do: Extension.get_opt(resource, [:global_index], :search_text_attribute, :search_text)

  @doc "Name of the generated read action."
  def action(resource), do: Extension.get_opt(resource, [:global_index], :action, :global_search)

  @doc "Whether `:global_search` also matches the label by trigram similarity/substring."
  def fuzzy?(resource), do: Extension.get_opt(resource, [:global_index], :fuzzy?, false)

  @doc "Minimum trigram similarity for a fuzzy label match."
  def fuzzy_threshold(resource),
    do: Extension.get_opt(resource, [:global_index], :fuzzy_threshold, 0.35)
end
