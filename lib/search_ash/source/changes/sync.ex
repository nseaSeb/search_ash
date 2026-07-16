defmodule SearchAsh.Source.Changes.Sync do
  @moduledoc false
  # Upserts the source record into its configured index on create/update.
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      index = SearchAsh.Source.Info.index(changeset.resource)
      attrs = SearchAsh.Source.Document.to_attrs(changeset.resource, record)

      index
      |> Ash.Changeset.for_create(:upsert, attrs, tenant: changeset.tenant)
      |> Ash.create!()

      {:ok, record}
    end)
  end
end
