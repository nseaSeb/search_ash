defmodule SearchDemo.Sales.Ligne do
  @moduledoc """
  A facture line. NOT a `SearchAsh.Source`: its text reaches the index through the
  facture's `extra_text` ("which factures mention tomatoes?"). A direct write here does
  not re-index the facture — that is the documented staleness contract; reconcile with
  `SearchAsh.reindex_one(Facture, id, tenant: org)` or any write to the facture.
  """
  use Ash.Resource,
    otp_app: :search_demo,
    domain: SearchDemo.Sales,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "facture_lignes"
    repo SearchDemo.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? true
  end

  actions do
    defaults [:read]

    create :create do
      accept [:facture_id, :designation]
    end

    update :update do
      accept [:designation]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :org_id, :string, allow_nil?: false, public?: true
    attribute :facture_id, :uuid, allow_nil?: false, public?: true
    attribute :designation, :string, public?: true

    timestamps()
  end

  relationships do
    belongs_to :facture, SearchDemo.Sales.Facture do
      source_attribute :facture_id
      define_attribute? false
      public? true
    end
  end
end
