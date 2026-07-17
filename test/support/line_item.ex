defmodule SearchAsh.Test.LineItem do
  @moduledoc false
  # Two jobs, deliberately in one fixture — both are properties no other test resource can
  # express (every other source has a single `uuid_primary_key` and no source-side policy):
  #
  #   * a COMPOSITE primary key, so `reindex_one/3`'s pk -> source_id must join the parts in
  #     `primary_key/1` order exactly as `Document.source_id/2` does from a record;
  #   * a read policy that FILTERS rather than forbids, so an *authorized* read returns nil
  #     for a live row — the "hidden looks deleted" trap `reindex_one/3` must not fall into.
  use Ash.Resource,
    domain: SearchAsh.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [SearchAsh.Source]

  postgres do
    table "test_line_items"
    repo SearchAsh.Test.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? true
  end

  searchable do
    index SearchAsh.Test.SearchDocument
    source_type :line_item
    fields [:description]
    label_field :description
    language :fr
  end

  policies do
    # Scoped by action type on purpose: Ash ANDs every *applicable* policy, so a bare
    # `policy always()` would also apply to reads and satisfy them, neutering the filter
    # below — and the security test would go green against a broken implementation.
    #
    # `authorize_if expr(hidden == false)` filters rather than forbids: a hidden row simply
    # *is not there* as far as an authorized read is concerned, which is precisely the
    # ambiguity `reindex_one/3` must not resolve as "deleted". A `forbid_if always()` would
    # make `Ash.get` return `{:error, Forbidden}` — loud, and not the bug being pinned.
    policy action_type(:read) do
      authorize_if expr(hidden == false)
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if always()
    end
  end

  actions do
    defaults [:read]

    create :create do
      accept [:order_id, :line_no, :description, :hidden]
    end

    update :update do
      accept [:description, :hidden]
    end

    destroy :destroy do
    end
  end

  attributes do
    attribute :order_id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :line_no, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :org_id, :string, allow_nil?: false, public?: true
    attribute :description, :string, public?: true
    attribute :hidden, :boolean, allow_nil?: false, default: false, public?: true
  end
end
