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

  alias SearchAsh.Source.{Index, Info}

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

  # Bulk (atomic_batches) path: mirror every updated record — through `upsert_all/4`, so
  # a `load`ed relationship costs one query per batch, not one per record. We don't apply
  # the `recompute?` short-circuit here — `changing_attribute?` isn't meaningful for an
  # atomic changeset, and re-upserting an unchanged row is harmless (idempotent upsert).
  # One bulk action carries one tenant/domain, so chunking keeps the (theoretical) mixed
  # batch correct without reordering anything.
  @impl true
  def after_batch(changesets_and_records, _opts, _context) do
    changesets_and_records
    |> Enum.chunk_by(fn {changeset, _record} -> {changeset.tenant, changeset.domain} end)
    |> Enum.flat_map(fn [{changeset, _record} | _] = chunk ->
      records = Enum.map(chunk, &elem(&1, 1))

      results =
        Index.upsert_all(changeset.resource, records, changeset.tenant, changeset.domain)

      Enum.flat_map(Enum.zip(records, results), fn {record, {_result, notifications}} ->
        [{:ok, record} | notifications]
      end)
    end)
  end

  defp sync(changeset, record) do
    case upsert(changeset, record) do
      [] -> {:ok, record}
      notifications -> {:ok, record, notifications}
    end
  end

  # Upserts the index row and returns the notifications it generated, so the calling hook can
  # hand them back to Ash for dispatch — otherwise they'd be "missed" inside the source
  # action's transaction. The write itself lives in `Source.Index`, shared with the destroy
  # path and with `SearchAsh.reindex/2`+`reindex_one/3`.
  defp upsert(changeset, record) do
    {_result, notifications} =
      Index.upsert(changeset.resource, record, changeset.tenant, changeset.domain)

    notifications
  end

  defp recompute?(changeset) do
    changeset.action_type == :create or recompute_on_update?(changeset)
  end

  # For an attribute-driven `archived`, recompute only when an indexed field, the language,
  # or the archived attribute changed. Recompute on *every* update when the document
  # depends on something `changing_attribute?` can't see: a function-driven `archived`,
  # or text derived from `extra_text`/`load` (relations managed through this action —
  # `manage_relationship` — never show up as a changing attribute).
  defp recompute_on_update?(changeset) do
    resource = changeset.resource

    cond do
      is_function(Info.archived(resource)) ->
        true

      Info.extra_texts(resource) != [] or Info.load(resource) ->
        true

      true ->
        Enum.any?(
          guarded_attributes(resource),
          &Ash.Changeset.changing_attribute?(changeset, &1)
        )
    end
  end

  defp guarded_attributes(resource) do
    # With a static language there is no language attribute to watch for changes on.
    language = if Info.language(resource), do: [], else: [Info.language_attribute(resource)]
    # The label is stored in the index too, so a change to it must re-sync even when it is not
    # one of the searchable `fields` (search the body, display the subject). Nil when no
    # `label_field` is configured.
    label = List.wrap(Info.label_field(resource))
    # Same for an attribute-driven `index_attribute`: changing only a document's date must
    # refresh the indexed date, even though no searchable field moved.
    derived = SearchAsh.Source.Document.index_attribute_attributes(resource)
    base = Info.fields(resource) ++ language ++ label ++ derived

    case Info.archived(resource) do
      attribute when is_atom(attribute) and not is_nil(attribute) -> [attribute | base]
      _fun_or_nil -> base
    end
  end
end
