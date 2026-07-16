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
    archived fn record -> not is_nil(record.deleted_at) end
    on_destroy :archive
  end

  actions do
    defaults [:read]

    create :create do
      accept [:number, :language]
    end

    update :update do
      require_atomic? false
      accept [:number, :deleted_at, :language]
    end

    destroy :destroy do
      require_atomic? false
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :org_id, :string, allow_nil?: false, public?: true
    attribute :number, :string, public?: true
    attribute :deleted_at, :utc_datetime_usec, public?: true

    attribute :language, :atom,
      allow_nil?: false,
      public?: true,
      default: :french,
      constraints: [one_of: Stemmers.supported_languages()]
  end
end
