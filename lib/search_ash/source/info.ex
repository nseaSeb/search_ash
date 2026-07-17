defmodule SearchAsh.Source.Info do
  @moduledoc "Read a resource's `searchable do … end` configuration."
  alias Spark.Dsl.Extension

  def index(resource), do: Extension.get_opt(resource, [:searchable], :index, nil)

  def source_type(resource),
    do: resource |> Extension.get_opt([:searchable], :source_type, nil) |> to_string()

  def fields(resource), do: Extension.get_opt(resource, [:searchable], :fields, [])

  @doc """
  The static language fixed for every row of this resource, or `nil` when the language is
  read per-row from `language_attribute/1`.
  """
  def language(resource), do: Extension.get_opt(resource, [:searchable], :language, nil)

  @doc """
  Attribute holding each row's language, defaulting to `:language`.

  Only meaningful when `language/1` is `nil`; the two are mutually exclusive.
  """
  def language_attribute(resource),
    do: Extension.get_opt(resource, [:searchable], :language_attribute, :language)

  @doc "Whether `language_attribute` was set explicitly, as opposed to falling back to `:language`."
  def language_attribute_configured?(resource),
    do: Extension.get_opt(resource, [:searchable], :language_attribute, nil) != nil

  def label_field(resource), do: Extension.get_opt(resource, [:searchable], :label_field, nil)

  @doc "Archived resolver: `nil`, an attribute name (truthiness), or a `record -> boolean`."
  def archived(resource), do: Extension.get_opt(resource, [:searchable], :archived, nil)

  @doc "`:remove` or `:archive` — index behaviour when the source is destroyed."
  def on_destroy(resource), do: Extension.get_opt(resource, [:searchable], :on_destroy, :remove)
end
