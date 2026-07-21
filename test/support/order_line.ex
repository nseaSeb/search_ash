defmodule SearchAsh.Test.OrderLine do
  @moduledoc false
  # NOT a SearchAsh.Source: a direct write here does not touch the order's index row.
  # That staleness is the documented `extra_text` contract, and the tests prove both
  # the staleness and the `reindex_one/3` repair.
  use Ash.Resource,
    domain: SearchAsh.Test.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "test_order_lines"
    repo SearchAsh.Test.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? true
  end

  actions do
    defaults [:read]

    create :create do
      accept [:order_id, :description]
    end

    update :update do
      accept [:description]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :org_id, :string, allow_nil?: false, public?: true
    attribute :order_id, :uuid, allow_nil?: false, public?: true
    attribute :description, :string, public?: true
  end

  relationships do
    belongs_to :order, SearchAsh.Test.Order do
      source_attribute :order_id
      define_attribute? false
      public? true
    end
  end
end
