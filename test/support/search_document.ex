defmodule SearchAsh.Test.SearchDocument do
  @moduledoc false
  use Ash.Resource,
    domain: SearchAsh.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [SearchAsh.GlobalIndex]

  postgres do
    table "test_search_documents"
    repo SearchAsh.Test.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? true
  end

  global_index do
    default_language :fr
    # Class :b priced almost level with :a, instead of Postgres' 0.4. Field-to-class is
    # each source's call; what a class is WORTH belongs here, or ranks from different
    # entity types would not be comparable.
    weight_values %{b: 0.9}
    # Query-time synonym expansion (inline per-language form). Keys chosen so no other
    # global-search test queries them: expansion only fires for a query token that hits a
    # key, so this leaves every other test's matches untouched.
    synonyms %{fr: %{"bl" => ["bon de livraison"], "cde" => ["commande"]}}
  end

  attributes do
    uuid_primary_key :id
    attribute :org_id, :string, allow_nil?: false, public?: true

    # Typed columns filled by sources' `index_attribute`. Declared here, on the index —
    # a source cannot add a column to a resource it does not own.
    attribute :document_date, :date, public?: true
    attribute :client_ref, :string, public?: true
    attribute :line_count, :integer, public?: true
    attribute :tags, {:array, :string}, public?: true
    attribute :montant, :decimal, public?: true
  end
end
