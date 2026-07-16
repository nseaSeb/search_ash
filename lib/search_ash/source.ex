defmodule SearchAsh.Source do
  @moduledoc """
  Ash extension that mirrors a resource into a `SearchAsh.GlobalIndex` so it shows up in
  the unified global search.

      defmodule MyApp.Sales.BonDeCommande do
        use Ash.Resource,
          domain: MyApp.Sales,
          data_layer: AshPostgres.DataLayer,
          extensions: [SearchAsh.Source]

        searchable do
          index MyApp.Search.Document
          source_type :bon_de_commande
          fields [:numero, :client_nom, :description]
          language_attribute :language
          label_field :numero
          state_attribute :status      # optional — its value becomes the index `state`
        end

        # ... attributes + a create action ...
        # update actions need `require_atomic? false` (stemming runs in a NIF).
      end

  On create/update it upserts a stemmed document into the index (tenant-aware); on destroy
  it removes it. With `state_attribute`, a soft delete (e.g. setting `status: :archived`)
  flows into the index `state`, so `:global_search` hides it while keeping the row.

  Backfill existing rows with `SearchAsh.reindex(MyApp.Sales.BonDeCommande)`.
  """

  @searchable %Spark.Dsl.Section{
    name: :searchable,
    describe: "Mirror this resource into a unified search index.",
    schema: [
      index: [
        type: {:spark, SearchAsh.GlobalIndex},
        required: true,
        doc: "The `SearchAsh.GlobalIndex` resource to feed."
      ],
      source_type: [
        type: {:or, [:atom, :string]},
        required: true,
        doc: "Tag identifying this resource's rows in the index (e.g. `:bon_de_commande`)."
      ],
      fields: [
        type: {:list, :atom},
        required: true,
        doc: "Attributes whose text is concatenated, stemmed and indexed."
      ],
      language_attribute: [
        type: :atom,
        default: :language,
        doc: "Attribute holding each row's language."
      ],
      label_field: [
        type: :atom,
        required: false,
        doc: "Attribute used as the human-readable label stored in the index."
      ],
      state_attribute: [
        type: :atom,
        required: false,
        doc:
          "Optional atom attribute whose value is copied into the index `state` " <>
            "(defaults to `:active`). Use it to drive soft-delete visibility."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@searchable],
    transformers: [SearchAsh.Source.Transformers.AddSync]
end
