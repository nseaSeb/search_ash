defmodule SearchAsh.Source.Info do
  @moduledoc "Read a resource's `searchable do … end` configuration."
  alias Spark.Dsl.Extension

  def index(resource), do: Extension.get_opt(resource, [:searchable], :index, nil)

  def source_type(resource),
    do: resource |> Extension.get_opt([:searchable], :source_type, nil) |> to_string()

  def fields(resource), do: Extension.get_opt(resource, [:searchable], :fields, [])

  def language_attribute(resource),
    do: Extension.get_opt(resource, [:searchable], :language_attribute, :language)

  def label_field(resource), do: Extension.get_opt(resource, [:searchable], :label_field, nil)

  @doc "State resolver: `nil`, an attribute name, or a `record -> atom` function."
  def state(resource), do: Extension.get_opt(resource, [:searchable], :state, nil)

  @doc "`:remove` or `{:set_state, atom}` — index behaviour when the source is destroyed."
  def on_destroy(resource), do: Extension.get_opt(resource, [:searchable], :on_destroy, :remove)
end
