defmodule SearchDemo.Search.Document do
  @moduledoc """
  Unified, cross-entity search index (Option B) via the `SearchAsh.GlobalIndex` extension.
  One row per indexed source object; `:global_search` ranks matches and returns
  `(source_type, source_id, org_id, state, label, search_rank)`.

  Multitenant by attribute (`org_id`): every read is tenant-scoped. Source resources feed
  it with `SearchAsh.Source` (see `SearchDemo.Sales.*`).

  ## Roles

  This index does not inherit the policies of the resources feeding it — it carries its
  own, and `:global_search` honours them because it is a plain Ash read action. A role
  decides **which entity types** a user may find:

  | role | finds |
  |---|---|
  | `:admin` | everything |
  | `:commercial` | factures + clients |
  | `:support` | clients |

  That is the granularity an index row can enforce: it holds `source_type`, not an owner.
  Row-level rules ("only *my* clients") belong on the source resource — see the
  limitations in the search_ash README.

  Try it in the console at `/cli`: `:actor user <id>`, then search. `:actor none` returns
  nothing, because the policies fail closed rather than open.
  """
  use Ash.Resource,
    otp_app: :search_demo,
    domain: SearchDemo.Search,
    data_layer: AshPostgres.DataLayer,
    extensions: [SearchAsh.GlobalIndex],
    authorizers: [Ash.Policy.Authorizer]

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
    # Typo tolerance on the label (duont → Dupont, 12 → BL-…-0012), served by a trigram
    # GIN index. Needs "pg_trgm" in the repo's installed_extensions.
    fuzzy? true
  end

  policies do
    # `source_type` is stored as a string, so compare against strings.
    #
    # No actor -> no clause matches -> nothing is returned. Failing closed is the point: a
    # search that returns everything when authorization is missing is how data leaks.
    policy action_type(:read) do
      authorize_if expr(^actor(:role) == :admin)
      authorize_if expr(^actor(:role) == :commercial and source_type in ["facture", "client"])
      authorize_if expr(^actor(:role) == :support and source_type == "client")
    end

    # Nothing else is declared on purpose. `SearchAsh.Source` mirrors rows with
    # `authorize?: false` — the source write it rides on was already authorized — so the
    # extension needs no policy here. Ash refuses an action no policy matches, which means
    # a *manual* write to this index is refused. That is the right default for a table
    # nobody should be hand-editing: grant it explicitly if you ever need to.
  end

  attributes do
    uuid_primary_key :id
    attribute :org_id, :string, allow_nil?: false, public?: true

    # Filled by sources' `index_attribute`. Declared here because a source cannot add a
    # column to a resource it does not own — this is the index's "mapping".
    attribute :document_date, :date, public?: true

    # A *keyword* column: stored raw, never analysed — for exact filtering and facets.
    # The source types it as an atom; the index keeps a flat string, which is all an
    # exact filter needs.
    attribute :statut, :string, public?: true

    # Un tableau et un numérique : le premier se filtre avec `has/2`, le second par
    # intervalle. Tous deux remplis par `index_attribute` depuis la source.
    attribute :tags, {:array, :string}, public?: true
    attribute :montant, :decimal, public?: true
  end
end
