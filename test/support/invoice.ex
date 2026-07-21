defmodule SearchAsh.Test.Invoice do
  @moduledoc false
  # Exercises soft-delete via a `deleted_at` timestamp: state is derived by a function,
  # and a destroy keeps the row archived instead of removing it.
  use Ash.Resource,
    domain: SearchAsh.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [SearchAsh.Source]

  postgres do
    table "test_invoices"
    repo SearchAsh.Test.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? true
  end

  searchable do
    index SearchAsh.Test.SearchDocument
    source_type :invoice
    fields [:number]
    label_field :number
    # Both combined with `on_destroy :archive` on purpose: the archive path re-upserts the
    # row rather than rebuilding the document, so this fixture pins that an archived row
    # keeps every stored column — the excerpt and the typed ones included.
    excerpt_length 50
    index_attribute :client_ref, :number
    # The SAME index column Order fills, from a DIFFERENT attribute: one comparable date
    # axis across entity types is what makes "most recent first" work on a mixed page.
    index_attribute :document_date, :date_facture
    archived fn record -> not is_nil(record.deleted_at) end
    on_destroy :archive
  end

  actions do
    defaults [:read]

    create :create do
      accept [:number, :language, :date_facture]
    end

    # NB: no `require_atomic? false` here — SearchAsh.Source sets it automatically.
    update :update do
      accept [:number, :deleted_at, :language, :date_facture]
    end

    destroy :destroy do
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :org_id, :string, allow_nil?: false, public?: true
    attribute :number, :string, public?: true
    attribute :date_facture, :date, public?: true
    attribute :deleted_at, :utc_datetime_usec, public?: true

    attribute :language, :atom,
      allow_nil?: false,
      public?: true,
      default: :fr,
      constraints: [one_of: SearchCore.Language.supported_languages()]
  end
end
