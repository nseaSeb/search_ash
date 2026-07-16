defmodule Blog.Search.Document do
  @moduledoc """
  Unified, cross-entity search index (Option B). One row per indexed source object,
  identified by `(source_type, source_id)`, holding the pre-stemmed `search_text`.

  Multitenant by attribute (`org_id`), so every read — including `:global_search` — is
  automatically scoped to the current tenant: a search can only ever return the calling
  org's rows. `org_id` is returned in results so callers can assert isolation.

  Rows are kept in sync by `Blog.Sales.Changes.SyncToIndex` on each source resource;
  `:global_search` ranks matches with `ts_rank` and returns `(source_type, source_id,
  org_id, label, rank)` — enough to link to the underlying object.
  """
  use Ash.Resource,
    otp_app: :blog,
    domain: Blog.Search,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "search_documents"
    repo Blog.Repo

    custom_indexes do
      index "(to_tsvector('simple', search_text))",
        using: "gin",
        name: "search_documents_search_idx",
        all_tenants?: true
    end
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    # Allow tenant-less reads (e.g. the GreenAsh admin console). Isolation still applies
    # whenever a tenant IS given — global_search from the app always passes one.
    global? true
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      accept [:source_type, :source_id, :language, :search_text, :label]
      upsert? true
      upsert_identity :unique_source
    end

    read :global_search do
      argument :query, :string, allow_nil?: false
      argument :language, :atom, allow_nil?: false
      prepare Blog.Search.Preparations.GlobalSearch
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :org_id, :string, allow_nil?: false, public?: true
    attribute :source_type, :string, allow_nil?: false, public?: true
    attribute :source_id, :string, allow_nil?: false, public?: true

    attribute :language, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: Stemmers.supported_languages()]

    attribute :search_text, :string, allow_nil?: false, public?: true
    attribute :label, :string, public?: true

    timestamps()
  end

  identities do
    # Per-tenant uniqueness of a source object; also the upsert target.
    identity :unique_source, [:org_id, :source_type, :source_id]
  end

  calculations do
    # Relevance score for a given tsquery; :global_search loads and sorts by it.
    calculate :rank,
              :float,
              expr(
                fragment(
                  "ts_rank(to_tsvector('simple', search_text), to_tsquery('simple', ?))",
                  ^arg(:tsquery)
                )
              ) do
      argument :tsquery, :string, allow_nil?: false
    end
  end
end
