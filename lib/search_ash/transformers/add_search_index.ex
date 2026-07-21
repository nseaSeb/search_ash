defmodule SearchAsh.Transformers.AddSearchIndex do
  @moduledoc """
  Adds the GIN expression index `to_tsvector('simple', <search_text>)` to the resource's
  Postgres `custom_indexes`, so migration generation emits and round-trips it. No-op for
  resources that are not backed by AshPostgres.
  """
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  @siblings [
    SearchAsh.Transformers.AddSearchTextAttribute,
    SearchAsh.Transformers.AddSyncChange,
    SearchAsh.Transformers.AddSearchRank,
    SearchAsh.Transformers.AddSearchAction,
    SearchAsh.Transformers.AddSearchIndex
  ]

  @impl true
  def transform(dsl) do
    table = Transformer.get_option(dsl, [:postgres], :table)

    if table do
      search_text = Transformer.get_option(dsl, [:search], :search_text_attribute) || :search_text
      name = Transformer.get_option(dsl, [:search], :index_name) || "#{table}_search_idx"
      # The column holds a weighted tsvector *literal*, so the index casts rather than
      # calling `to_tsvector` — the query side must use the identical expression.
      expression = "(#{search_text}::tsvector)"

      if index_defined?(dsl, name) do
        {:ok, dsl}
      else
        {:ok, index} =
          Transformer.build_entity(AshPostgres.DataLayer, [:postgres, :custom_indexes], :index,
            fields: [expression],
            using: "gin",
            name: name,
            # Keep the GIN index global. With attribute multitenancy, the default
            # (`all_tenants?: false`) would try to fold the tenant column into the
            # index — Postgres can't mix a scalar column into a GIN tsvector index.
            # Tenant scoping still happens via Ash's automatic tenant filter.
            all_tenants?: true
          )

        {:ok, Transformer.add_entity(dsl, [:postgres, :custom_indexes], index)}
      end
    else
      {:ok, dsl}
    end
  end

  defp index_defined?(dsl, name) do
    dsl
    |> Transformer.get_entities([:postgres, :custom_indexes])
    |> Enum.any?(&(&1.name == name))
  end

  @impl true
  def before?(t), do: t not in @siblings
end
