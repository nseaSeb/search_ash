defmodule SearchAsh.Source.Changes.Sync do
  @moduledoc false
  # Upserts the source record into its configured index on create/update.
  #
  # The change touches no source attribute — it only mirrors the final record into a
  # separate index table — so it is atomic-compatible (`atomic/3` returns `:ok`). That
  # lets bulk create/update pick the default `:atomic_batches` strategy and mirror each
  # updated record in `after_batch/3`, with no `strategy:` option required from callers.
  #
  # Single-record updates run through `change/3` (the action carries `require_atomic?
  # false`); because `change/3` is defined, Ash does NOT also wire `after_batch/3` into the
  # single path, so a record is never synced twice.
  #
  # Perf note: the single-record path short-circuits via `recompute?` (skips the stemmer
  # when no indexed field changed); the bulk `after_batch/3` path re-stems every updated
  # row, since `changing_attribute?` isn't meaningful for an atomic changeset.
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

  # No atomic modification to the source record; the mirroring happens in `after_batch/3`.
  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  # Bulk (atomic_batches) path: mirror every updated record. We don't apply the
  # `recompute?` short-circuit here — `changing_attribute?` isn't meaningful for an atomic
  # changeset, and re-upserting an unchanged row is harmless (idempotent upsert).
  @impl true
  def after_batch(changesets_and_records, _opts, _context) do
    Enum.flat_map(changesets_and_records, fn {changeset, record} ->
      notifications = upsert(changeset.resource, record, changeset.tenant)
      [{:ok, record} | notifications]
    end)
  end

  defp sync(changeset, record) do
    case upsert(changeset.resource, record, changeset.tenant) do
      [] -> {:ok, record}
      notifications -> {:ok, record, notifications}
    end
  end

  # Upserts the index row and returns the notifications it generated (so the calling hook
  # can hand them back to Ash for dispatch — otherwise they'd be "missed" inside the
  # source action's transaction). Returns [] for a partially-loaded record (narrowed
  # `select`), which is left as-is rather than indexed from incomplete data.
  defp upsert(resource, record, tenant) do
    if Document.loaded?(resource, record) do
      {_indexed, notifications} =
        Info.index(resource)
        |> Ash.Changeset.for_create(:upsert, Document.to_attrs(resource, record), tenant: tenant)
        |> Ash.create!(return_notifications?: true)

      notifications
    else
      []
    end
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
    # With a static language there is no language attribute to watch for changes on.
    language = if Info.language(resource), do: [], else: [Info.language_attribute(resource)]
    base = Info.fields(resource) ++ language

    case Info.archived(resource) do
      attribute when is_atom(attribute) and not is_nil(attribute) -> [attribute | base]
      _fun_or_nil -> base
    end
  end
end
