defmodule SearchDemo.Search.Document do
  @moduledoc """
  Unified, cross-entity search index (Option B) via the `SearchAsh.GlobalIndex` extension.
  One row per indexed source object; `:global_search` ranks matches and returns
  `(source_type, source_id, org_id, state, label, search_rank)`.

  Multitenant by attribute (`org_id`): every read is tenant-scoped. Source resources feed
  it with `SearchAsh.Source` (see `SearchDemo.Sales.*`).
  """
  use Ash.Resource,
    otp_app: :search_demo,
    domain: SearchDemo.Search,
    data_layer: AshPostgres.DataLayer,
    extensions: [SearchAsh.GlobalIndex]

  # Shown as this resource's label in the GreenAsh main menu.
  resource do
    description "Recherche globale — factures, clients, produits (rankée)"
  end

  postgres do
    table "search_documents"
    repo SearchDemo.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    # Allow tenant-less reads (e.g. the GreenAsh admin console). Isolation still applies
    # whenever a tenant IS given — global_search from the app always passes one.
    global? true
  end

  global_index do
    default_language :fr
  end

  attributes do
    uuid_primary_key :id
    attribute :org_id, :string, allow_nil?: false, public?: true
  end
end
