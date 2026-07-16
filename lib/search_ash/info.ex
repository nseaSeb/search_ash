defmodule SearchAsh.Info do
  @moduledoc "Read a resource's `search do … end` configuration."
  alias Spark.Dsl.Extension

  @doc "Attributes indexed for search."
  def fields(resource), do: Extension.get_opt(resource, [:search], :fields, [])

  @doc "Attribute holding each row's language."
  def language_attribute(resource),
    do: Extension.get_opt(resource, [:search], :language_attribute, :language)

  @doc "Attribute the stemmed tokens are stored in."
  def search_text_attribute(resource),
    do: Extension.get_opt(resource, [:search], :search_text_attribute, :search_text)

  @doc "Configured GIN index name, or nil to derive it from the table."
  def index_name(resource), do: Extension.get_opt(resource, [:search], :index_name, nil)

  @doc "Name of the generated read action."
  def action(resource), do: Extension.get_opt(resource, [:search], :action, :search)

  @doc "Language used to stem the query when the search argument is omitted."
  def default_language(resource),
    do: Extension.get_opt(resource, [:search], :default_language, :french)

  @doc "Whether the search matches the query tokens as prefixes (search-as-you-type)."
  def prefix?(resource), do: Extension.get_opt(resource, [:search], :prefix?, true)
end
