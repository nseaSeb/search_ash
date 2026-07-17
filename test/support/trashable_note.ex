defmodule SearchAsh.Test.TrashableNote do
  @moduledoc false
  # Soft delete via `base_filter`, the way a trash feature (or AshArchival) actually works:
  # the row stays physically present and `is_nil(deleted_at)` hides it from every read.
  #
  # This is the shape `reindex_one/3` exists for. The other fixtures simulate a gone source
  # with a physical DELETE, which exercises the same branch by a different route — but the
  # production trigger is a raw-SQL cascade that only *stamps* `deleted_at`. What must hold is
  # that `base_filter` is applied independently of `authorize?`, so the read still reports the
  # row as gone and the dead branch runs.
  use Ash.Resource,
    domain: SearchAsh.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [SearchAsh.Source]

  postgres do
    table "test_trashable_notes"
    repo SearchAsh.Test.Repo
  end

  resource do
    base_filter expr(is_nil(deleted_at))
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? true
  end

  searchable do
    index SearchAsh.Test.SearchDocument
    source_type :trashable_note
    fields [:title]
    label_field :title
    language :fr
    on_destroy :remove
  end

  actions do
    defaults [:read]

    create :create do
      accept [:title]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :org_id, :string, allow_nil?: false, public?: true
    attribute :title, :string, public?: true
    attribute :deleted_at, :utc_datetime_usec, public?: true
  end
end
