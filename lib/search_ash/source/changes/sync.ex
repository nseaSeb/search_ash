defmodule SearchAsh.Source.Changes.Sync do
  @moduledoc false
  # Upserts the source record into its configured index on create/update. Only recomputes
  # when something the index depends on changed, and never from a partially-loaded record.
  use Ash.Resource.Change

  alias SearchAsh.Source.{Document, Info}

  @impl true
  def change(changeset, _opts, _context) do
    if recompute?(changeset) do
      Ash.Changeset.after_action(changeset, &sync/2)
    else
      changeset
    end
  end

  defp sync(changeset, record) do
    resource = changeset.resource

    if Document.loaded?(resource, record) do
      Info.index(resource)
      |> Ash.Changeset.for_create(:upsert, Document.to_attrs(resource, record),
        tenant: changeset.tenant
      )
      |> Ash.create!()
    end

    # A partially-loaded record (narrowed `select`) is left as-is rather than indexed from
    # incomplete data.
    {:ok, record}
  end

  defp recompute?(changeset) do
    changeset.action_type == :create or recompute_on_update?(changeset)
  end

  # For an attribute-driven `archived`, recompute only when an indexed field, the language,
  # or the archived attribute changed. For a function-driven `archived` we can't introspect
  # its inputs, so recompute on every update.
  defp recompute_on_update?(changeset) do
    case Info.archived(changeset.resource) do
      fun when is_function(fun) ->
        true

      _attribute_or_nil ->
        Enum.any?(
          guarded_attributes(changeset.resource),
          &Ash.Changeset.changing_attribute?(changeset, &1)
        )
    end
  end

  defp guarded_attributes(resource) do
    base = Info.fields(resource) ++ [Info.language_attribute(resource)]

    case Info.archived(resource) do
      attribute when is_atom(attribute) and not is_nil(attribute) -> [attribute | base]
      _fun_or_nil -> base
    end
  end
end
