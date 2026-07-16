defmodule SearchAsh.Source.Changes.Remove do
  @moduledoc false
  # Removes the source record's row from its configured index on destroy.
  use Ash.Resource.Change
  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      resource = changeset.resource
      index = SearchAsh.Source.Info.index(resource)
      source_type = SearchAsh.Source.Info.source_type(resource)
      source_id = SearchAsh.Source.Document.source_id(resource, record)

      index
      |> Ash.Query.filter(source_type == ^source_type and source_id == ^source_id)
      |> Ash.read!(tenant: changeset.tenant)
      |> Enum.each(&Ash.destroy!(&1, tenant: changeset.tenant))

      {:ok, record}
    end)
  end
end
