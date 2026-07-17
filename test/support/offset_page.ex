defmodule SearchAsh.Test.OffsetPage do
  @moduledoc false
  # A source whose primary read cannot be keyset-streamed (pagination is offset-only). Ash
  # streams with `:keyset` by default, so `Ash.stream!` on this resource raises
  # `NonStreamableAction` unless the caller passes `stream_with: :offset`. It exists to pin
  # that `prune/2` forwards that option to the source stream — a resource with a filtered or
  # non-keyset default read is common enough that dropping it silently broke prune in practice.
  use Ash.Resource,
    domain: SearchAsh.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [SearchAsh.Source]

  postgres do
    table "test_offset_pages"
    repo SearchAsh.Test.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? true
  end

  searchable do
    index SearchAsh.Test.SearchDocument
    source_type :offset_page
    fields [:title]
    label_field :title
    language :fr
  end

  actions do
    create :create do
      accept [:title]
    end

    read :read do
      primary? true
      pagination offset?: true, keyset?: false, required?: false
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :org_id, :string, allow_nil?: false, public?: true
    attribute :title, :string, public?: true
  end
end
