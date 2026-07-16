defmodule SearchAsh.GlobalIndex.Transformers.AddActions do
  @moduledoc """
  Adds the `:upsert` action, the `:global_search` read action, the `:search_rank`
  calculation, and default `:read`/`:destroy` actions to a `SearchAsh.GlobalIndex`
  resource (each only if absent).
  """
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer
  import Ash.Expr

  @siblings [
    SearchAsh.GlobalIndex.Transformers.AddSchema,
    SearchAsh.GlobalIndex.Transformers.AddActions
  ]

  @accept [:source_type, :source_id, :language, :search_text, :archived, :label]

  @impl true
  def transform(dsl) do
    action_name = Transformer.get_option(dsl, [:global_index], :action) || :global_search

    search_text =
      Transformer.get_option(dsl, [:global_index], :search_text_attribute) || :search_text

    dsl
    |> ensure_default_action(:read, [])
    |> ensure_default_action(:destroy, [])
    |> add_upsert_action()
    |> add_search_rank(search_text)
    |> add_global_search_action(action_name)
    |> then(&{:ok, &1})
  end

  # Ensure a PRIMARY action of this type exists (the Remove change reads/destroys the
  # index via the primary read/destroy). Only add ours if none is already primary.
  defp ensure_default_action(dsl, type, opts) do
    if primary_action?(dsl, type) do
      dsl
    else
      {:ok, action} =
        Ash.Resource.Builder.build_action(type, type, Keyword.put(opts, :primary?, true))

      Transformer.add_entity(dsl, [:actions], action)
    end
  end

  defp primary_action?(dsl, type) do
    dsl
    |> Transformer.get_entities([:actions])
    |> Enum.any?(&(&1.type == type and &1.primary?))
  end

  defp add_upsert_action(dsl) do
    if action_defined?(dsl, :upsert) do
      dsl
    else
      {:ok, action} =
        Ash.Resource.Builder.build_action(:create, :upsert,
          accept: @accept,
          upsert?: true,
          upsert_identity: :unique_source
        )

      Transformer.add_entity(dsl, [:actions], action)
    end
  end

  defp add_search_rank(dsl, search_text) do
    if calc_defined?(dsl, :search_rank) do
      dsl
    else
      calc_expr =
        Ash.Expr.expr(
          fragment(
            "ts_rank(to_tsvector('simple', ?), to_tsquery('simple', ?))",
            ^ref(search_text),
            ^arg(:tsquery)
          )
        )

      {:ok, argument} =
        Ash.Resource.Builder.build_calculation_argument(:tsquery, :string, allow_nil?: false)

      {:ok, calc} =
        Ash.Resource.Builder.build_calculation(:search_rank, :float, calc_expr,
          arguments: [argument]
        )

      Transformer.add_entity(dsl, [:calculations], calc)
    end
  end

  defp add_global_search_action(dsl, action_name) do
    if action_defined?(dsl, action_name) do
      dsl
    else
      {:ok, query_arg} =
        Ash.Resource.Builder.build_action_argument(:query, :string, allow_nil?: true, default: "")

      {:ok, language_arg} =
        Ash.Resource.Builder.build_action_argument(:language, :atom, allow_nil?: true)

      {:ok, include_archived_arg} =
        Ash.Resource.Builder.build_action_argument(:include_archived?, :boolean,
          allow_nil?: false,
          default: false
        )

      {:ok, preparation} =
        Ash.Resource.Builder.build_preparation(
          SearchAsh.GlobalIndex.Preparations.GlobalSearch,
          []
        )

      {:ok, action} =
        Ash.Resource.Builder.build_action(:read, action_name,
          arguments: [query_arg, language_arg, include_archived_arg],
          preparations: [preparation]
        )

      Transformer.add_entity(dsl, [:actions], action)
    end
  end

  defp action_defined?(dsl, name) do
    dsl |> Transformer.get_entities([:actions]) |> Enum.any?(&(&1.name == name))
  end

  defp calc_defined?(dsl, name) do
    dsl |> Transformer.get_entities([:calculations]) |> Enum.any?(&(&1.name == name))
  end

  @impl true
  def before?(t), do: t not in @siblings
end
