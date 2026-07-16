defmodule SearchDemo.Sales.Changes.RemoveFromIndex do
  @moduledoc """
  Companion to `SyncToIndex`: on destroy, removes the source object's row from the
  unified `SearchDemo.Search.Document` index so deleted objects stop appearing in search.
  Runs in `after_action` (the destroyed record — and its id — is available) and is
  tenant-scoped.

  Options: `:source_type` — the string tag used when the row was indexed.
  """
  use Ash.Resource.Change
  require Ash.Query

  @impl true
  def change(changeset, opts, _context) do
    source_type = Keyword.fetch!(opts, :source_type)

    Ash.Changeset.after_action(changeset, fn changeset, record ->
      source_id = to_string(record.id)

      SearchDemo.Search.Document
      |> Ash.Query.filter(source_type == ^source_type and source_id == ^source_id)
      |> Ash.read!(tenant: changeset.tenant)
      |> Enum.each(&Ash.destroy!(&1, tenant: changeset.tenant))

      {:ok, record}
    end)
  end
end
