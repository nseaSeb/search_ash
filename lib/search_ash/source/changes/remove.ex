defmodule SearchAsh.Source.Changes.Remove do
  @moduledoc false
  # On destroy: either remove the source record's index row (`on_destroy: :remove`, hard
  # delete) or keep it flagged archived (`on_destroy: :archive`, soft delete via a destroy
  # action such as AshArchival).
  use Ash.Resource.Change
  require Ash.Query

  alias SearchAsh.Source.{Document, Info}

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      resource = changeset.resource

      case Info.on_destroy(resource) do
        :archive -> archive(resource, record, changeset.tenant)
        _remove -> remove(resource, record, changeset.tenant)
      end

      {:ok, record}
    end)
  end

  defp remove(resource, record, tenant) do
    index = Info.index(resource)
    source_type = Info.source_type(resource)
    source_id = Document.source_id(resource, record)

    index
    |> Ash.Query.filter(source_type == ^source_type and source_id == ^source_id)
    |> Ash.read!(tenant: tenant)
    |> Enum.each(&Ash.destroy!(&1, tenant: tenant))
  end

  defp archive(resource, record, tenant) do
    index = Info.index(resource)
    attrs = resource |> Document.to_attrs(record) |> Map.put(:archived, true)

    index
    |> Ash.Changeset.for_create(:upsert, attrs, tenant: tenant)
    |> Ash.create!()
  end
end
