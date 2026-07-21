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

  # The upsert accepts every public, writable, non-primary-key attribute of the index —
  # computed rather than listed, so an attribute the user adds for `index_attribute` is
  # accepted without touching this file, and a column added here can never be forgotten
  # in the accept list (a class of bug this extension has already shipped once).
  #
  # The attribute-multitenancy column is excluded: it is set from the `tenant:` option, and
  # accepting it would make Ash demand it in the attrs map (`allow_nil?: false`) on every
  # index write.
  defp accept(dsl) do
    excluded = tenant_attribute(dsl)

    dsl
    |> Transformer.get_entities([:attributes])
    |> Enum.reject(&(&1.primary_key? or not &1.public? or not &1.writable?))
    |> Enum.map(& &1.name)
    |> Enum.reject(&(&1 in excluded))
  end

  defp tenant_attribute(dsl) do
    case Transformer.get_option(dsl, [:multitenancy], :strategy) do
      :attribute -> [Transformer.get_option(dsl, [:multitenancy], :attribute)]
      _ -> []
    end
  end

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
    |> add_label_match_tier()
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
          accept: accept(dsl),
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
      # The weight array prices the four classes `weights` assigns fields to. Passed as a
      # bound parameter rather than inlined, so `weight_values` needs no string building.
      weight_values =
        dsl
        |> Transformer.get_option([:global_index], :weight_values, %{})
        |> SearchAsh.Weights.to_array()

      calc_expr =
        Ash.Expr.expr(
          fragment(
            "ts_rank(?::float4[], ?::tsvector, to_tsquery('simple', ?))",
            ^weight_values,
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

  # How the *label* relates to the folded query term: 0 exact, 1 starts-with, 2 contains,
  # 3 anything else (body-only match — including rows indexed before 0.4.0, whose
  # `label_normalized` is NULL: every comparison is NULL there, so they fall to ELSE).
  # `strpos` rather than LIKE: plain substring semantics, no pattern metacharacters to
  # escape — and as a sort key it runs on already-filtered rows, so it needs no index.
  defp add_label_match_tier(dsl) do
    if calc_defined?(dsl, :label_match_tier) do
      dsl
    else
      calc_expr =
        Ash.Expr.expr(
          fragment(
            "CASE WHEN ? = ? THEN 0 WHEN strpos(?, ?) = 1 THEN 1 WHEN strpos(?, ?) > 0 THEN 2 ELSE 3 END",
            ^ref(:label_normalized),
            ^arg(:term),
            ^ref(:label_normalized),
            ^arg(:term),
            ^ref(:label_normalized),
            ^arg(:term)
          )
        )

      {:ok, argument} =
        Ash.Resource.Builder.build_calculation_argument(:term, :string, allow_nil?: false)

      {:ok, calc} =
        Ash.Resource.Builder.build_calculation(:label_match_tier, :integer, calc_expr,
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

      # `nil` and `[]` both mean "no type filter" — an empty multi-select in a UI must
      # not silently turn into `source_type in []` (zero results).
      #
      # `{:array, :string}`, NOT `{:array, :atom}`: Ash's string type casts atoms via
      # `to_string`, so both `[:facture]` and `["facture"]` work — whereas the atom type
      # casts strings with `String.to_existing_atom`, which raises for a `source_type`
      # that was declared as a string in the DSL (its atom never exists) the moment a
      # form submits it.
      {:ok, types_arg} =
        Ash.Resource.Builder.build_action_argument(:types, {:array, :string}, allow_nil?: true)

      {:ok, preparation} =
        Ash.Resource.Builder.build_preparation(
          SearchAsh.GlobalIndex.Preparations.GlobalSearch,
          []
        )

      {:ok, pagination} = Ash.Resource.Builder.build_pagination(pagination_opts(dsl))

      {:ok, action} =
        Ash.Resource.Builder.build_action(:read, action_name,
          arguments: [query_arg, language_arg, include_archived_arg, types_arg],
          preparations: [preparation],
          pagination: pagination
        )

      Transformer.add_entity(dsl, [:actions], action)
    end
  end

  # Offset and keyset, never required — an unpaginated call still returns a plain list.
  # `default_limit` flips `paginate_by_default?` with it: asking for a default bound only
  # means something if a caller who passes no page gets it, and that is what makes the
  # action return a page rather than reading every matching row.
  defp pagination_opts(dsl) do
    default_limit = Transformer.get_option(dsl, [:global_index], :default_limit)

    [offset?: true, keyset?: true, countable: true, required?: false]
    |> put_unless_nil(:default_limit, default_limit)
    |> Keyword.put(:paginate_by_default?, not is_nil(default_limit))
  end

  defp put_unless_nil(opts, _key, nil), do: opts
  defp put_unless_nil(opts, key, value), do: Keyword.put(opts, key, value)

  defp action_defined?(dsl, name) do
    dsl |> Transformer.get_entities([:actions]) |> Enum.any?(&(&1.name == name))
  end

  defp calc_defined?(dsl, name) do
    dsl |> Transformer.get_entities([:calculations]) |> Enum.any?(&(&1.name == name))
  end

  @impl true
  def before?(t), do: t not in @siblings

  # `accept/1` reads the index's attributes, which `AddSchema` is what adds — so the
  # order between the two siblings is load-bearing, not incidental.
  @impl true
  def after?(SearchAsh.GlobalIndex.Transformers.AddSchema), do: true
  def after?(_), do: false
end
