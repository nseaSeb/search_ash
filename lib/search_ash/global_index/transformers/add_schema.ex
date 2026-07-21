defmodule SearchAsh.GlobalIndex.Transformers.AddSchema do
  @moduledoc """
  Adds the index columns, the `unique_source` identity (tenant-aware) and the GIN index
  to a `SearchAsh.GlobalIndex` resource.
  """
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  @siblings [
    SearchAsh.GlobalIndex.Transformers.AddSchema,
    SearchAsh.GlobalIndex.Transformers.AddActions
  ]

  @impl true
  def transform(dsl) do
    search_text =
      Transformer.get_option(dsl, [:global_index], :search_text_attribute) || :search_text

    dsl
    |> add_new_pkey()
    |> add_attribute(:source_type, :string, allow_nil?: false, public?: true)
    |> add_attribute(:source_id, :string, allow_nil?: false, public?: true)
    |> add_attribute(:language, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: SearchCore.Language.supported_languages()]
    )
    |> add_attribute(search_text, :string, allow_nil?: true, public?: true)
    |> add_attribute(:archived, :boolean, allow_nil?: false, public?: true, default: false)
    |> add_attribute(:label, :string, public?: true)
    |> add_attribute(:label_normalized, :string, allow_nil?: true, public?: true)
    |> add_attribute(:excerpt, :string, allow_nil?: true, public?: true)
    |> add_identity()
    |> add_gin_index(search_text)
    |> maybe_add_trigram_index()
    |> then(&{:ok, &1})
  end

  defp add_new_pkey(dsl) do
    has_pkey? =
      dsl
      |> Transformer.get_entities([:attributes])
      |> Enum.any?(& &1.primary_key?)

    if has_pkey? do
      dsl
    else
      {:ok, attr} =
        Ash.Resource.Builder.build_attribute(:id, :uuid,
          primary_key?: true,
          allow_nil?: false,
          public?: true,
          default: &Ash.UUID.generate/0
        )

      Transformer.add_entity(dsl, [:attributes], attr)
    end
  end

  defp add_attribute(dsl, name, type, opts) do
    exists? =
      dsl
      |> Transformer.get_entities([:attributes])
      |> Enum.any?(&(&1.name == name))

    if exists? do
      dsl
    else
      {:ok, attr} = Ash.Resource.Builder.build_attribute(name, type, opts)
      Transformer.add_entity(dsl, [:attributes], attr)
    end
  end

  defp add_identity(dsl) do
    if identity_defined?(dsl, :unique_source) do
      dsl
    else
      keys = tenant_attribute(dsl) ++ [:source_type, :source_id]
      {:ok, identity} = Ash.Resource.Builder.build_identity(:unique_source, keys)
      Transformer.add_entity(dsl, [:identities], identity)
    end
  end

  defp identity_defined?(dsl, name) do
    dsl |> Transformer.get_entities([:identities]) |> Enum.any?(&(&1.name == name))
  end

  defp add_gin_index(dsl, search_text) do
    case Transformer.get_option(dsl, [:postgres], :table) do
      nil ->
        dsl

      table ->
        {:ok, index} =
          Transformer.build_entity(AshPostgres.DataLayer, [:postgres, :custom_indexes], :index,
            # The column holds a weighted tsvector *literal*, so the index casts rather
            # than calling `to_tsvector` — the query side uses the identical expression.
            fields: ["(#{search_text}::tsvector)"],
            using: "gin",
            name: "#{table}_search_idx",
            all_tenants?: true
          )

        Transformer.add_entity(dsl, [:postgres, :custom_indexes], index)
    end
  end

  # Only when `fuzzy? true`: a trigram GIN index on the folded label, serving both the
  # `%` similarity match and the `LIKE '%…%'` substring match of `:global_search`.
  # Requires the `pg_trgm` extension (the user adds `"pg_trgm"` to their repo's
  # `installed_extensions`) — which is exactly why this is opt-in.
  defp maybe_add_trigram_index(dsl) do
    with true <- Transformer.get_option(dsl, [:global_index], :fuzzy?, false),
         table when not is_nil(table) <- Transformer.get_option(dsl, [:postgres], :table) do
      {:ok, index} =
        Transformer.build_entity(AshPostgres.DataLayer, [:postgres, :custom_indexes], :index,
          fields: ["label_normalized gin_trgm_ops"],
          using: "gin",
          name: "#{table}_label_trgm_idx",
          all_tenants?: true
        )

      Transformer.add_entity(dsl, [:postgres, :custom_indexes], index)
    else
      _ -> dsl
    end
  end

  # Include the attribute-multitenancy tenant column in the identity so uniqueness (and
  # the upsert target) is per-tenant.
  defp tenant_attribute(dsl) do
    case Transformer.get_option(dsl, [:multitenancy], :strategy) do
      :attribute -> [Transformer.get_option(dsl, [:multitenancy], :attribute)]
      _ -> []
    end
  end

  @impl true
  def before?(t), do: t not in @siblings
end
