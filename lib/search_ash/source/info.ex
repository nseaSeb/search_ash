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

  def state_attribute(resource),
    do: Extension.get_opt(resource, [:searchable], :state_attribute, nil)
end
