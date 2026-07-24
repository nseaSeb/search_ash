defmodule SearchAsh.Info do
  @moduledoc "Read a resource's `search do … end` configuration."
  alias Spark.Dsl.Extension

  @doc "Attributes indexed for search."
  def fields(resource), do: Extension.get_opt(resource, [:search], :fields, [])

  @doc "Per-field rank weights (`%{field => :a | :b | :c | :d}`); unlisted fields are `:d`."
  def weights(resource), do: Extension.get_opt(resource, [:search], :weights, %{})

  @doc "The `{text, weight}` segments for `record`, in `fields` order."
  def segments(resource, values) do
    weights = weights(resource)

    resource
    |> fields()
    |> Enum.zip(values)
    |> Enum.map(fn {field, value} ->
      {SearchAsh.Text.indexable(value), Map.get(weights, field, :d)}
    end)
  end

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
    do: Extension.get_opt(resource, [:search], :default_language, :fr)

  @doc "Whether the search matches the query tokens as prefixes (search-as-you-type)."
  def prefix?(resource), do: Extension.get_opt(resource, [:search], :prefix?, true)

  @doc "Whether results are ranked by ts_rank (and the :search_rank calc is exposed)."
  def rank?(resource), do: Extension.get_opt(resource, [:search], :rank?, true)

  @doc """
  Synonym map to expand the query with for `language` (see `SearchAsh.Synonyms.resolve/2`).
  `%{}` when unset, so callers can pass the result straight to `SearchCore.tsquery/3`.
  """
  def synonyms(resource, language),
    do:
      resource
      |> Extension.get_opt([:search], :synonyms, nil)
      |> SearchAsh.Synonyms.resolve(language)
end
