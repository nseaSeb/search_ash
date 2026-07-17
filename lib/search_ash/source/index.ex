defmodule SearchAsh.Source.Index do
  @moduledoc false
  # The single place index rows are written. Shared by `Changes.Sync`, `Changes.Remove`,
  # `SearchAsh.reindex/2` and `SearchAsh.reindex_one/3`, so what `on_destroy` *means* cannot
  # drift between the action path and the manual path — `reindex_one/3` exists precisely to
  # agree with a destroy it never saw.
  #
  # `apply_destroy/3` works from `(source_type, source_id)` alone and never needs the source
  # record, which is what lets `reindex_one/3` reconcile a row whose source is already gone.
  #
  # Every function returns `{result, notifications}` and dispatches nothing: index writes
  # always run with `return_notifications?: true`, and only the caller knows whether it is
  # inside a source action's transaction (hand them back up through the hook) or outside one
  # (`Ash.Notifier.notify/1`).
  #
  # `authorize?: false` on every index write: mirroring is machinery, not a user action. The
  # source write it rides on was already authorized by the source's own policies, and the
  # index's policies express what a user may *find* — a different question. Re-authorizing the
  # mirror against them would make `SearchAsh.Source` break the moment an index carries
  # policies.
  require Ash.Query

  alias SearchAsh.Source.{Document, Info}

  @type result :: SearchAsh.reindex_result()

  @doc """
  Upsert `record`'s document into its index.

  Returns `{:noop, []}` for a partially-loaded record (narrowed `select`), which is left
  as-is rather than indexed from incomplete data.
  """
  @spec upsert(module(), struct(), term()) :: {result(), list()}
  def upsert(resource, record, tenant) do
    if Document.loaded?(resource, record) do
      {_indexed, notifications} =
        resource
        |> Info.index()
        |> Ash.Changeset.for_create(:upsert, Document.to_attrs(resource, record), tenant: tenant)
        |> Ash.create!(authorize?: false, return_notifications?: true)

      {:upserted, notifications}
    else
      {:noop, []}
    end
  end

  @doc """
  Apply the source's `on_destroy` behaviour to the index row(s) for `source_id`.

  `:remove` deletes them, `:archive` keeps them flagged `archived: true`. If nothing is
  indexed for this source, there is nothing to do.
  """
  @spec apply_destroy(module(), String.t(), term()) :: {result(), list()}
  def apply_destroy(resource, source_id, tenant) do
    case Info.on_destroy(resource) do
      :archive -> archive(resource, source_id, tenant)
      _remove -> remove(resource, source_id, tenant)
    end
  end

  defp remove(resource, source_id, tenant) do
    case indexed_rows(resource, source_id, tenant) do
      [] ->
        {:noop, []}

      rows ->
        notifications =
          Enum.flat_map(
            rows,
            &Ash.destroy!(&1, tenant: tenant, authorize?: false, return_notifications?: true)
          )

        {:removed, notifications}
    end
  end

  # Flip `archived` on the existing index row(s), reusing the row's own already-stemmed values
  # rather than rebuilding the document from the source record: it avoids re-running the
  # stemmer on a destroy, doesn't depend on the source record's searchable fields being
  # loaded — and, on the `reindex_one/3` path, is the only option, since the source is gone.
  #
  # An already-archived row is skipped: it is in its terminal state, so re-archiving it would
  # be a no-op write plus a spurious notification. Skipping keeps `reindex_one/3` genuinely
  # idempotent on the archive branch, and mirrors `prunable_source_ids/2`'s `exclude_terminal`.
  defp archive(resource, source_id, tenant) do
    index = Info.index(resource)

    case Enum.reject(indexed_rows(resource, source_id, tenant), & &1.archived) do
      [] ->
        {:noop, []}

      rows ->
        notifications =
          Enum.flat_map(rows, fn row ->
            {_indexed, notifications} =
              index
              |> Ash.Changeset.for_create(:upsert, archived_attrs(row), tenant: tenant)
              |> Ash.create!(authorize?: false, return_notifications?: true)

            notifications
          end)

        {:archived, notifications}
    end
  end

  @doc """
  The `source_id`s of index rows `SearchAsh.prune/2` may act on for `resource` (in `tenant`).

  These are the rows whose source *could* be a missing orphan — `prune/2` diffs them against
  the live source set. For an `on_destroy: :archive` resource, a row already flagged
  `archived` is in its terminal state: a gone source leaves an archived tombstone by design,
  and re-archiving it every sweep would be a no-op write plus a spurious notification, and
  would keep `prune/2`'s count from ever reaching zero. So archived rows are excluded there.
  For `:remove`, terminal means *absent* from the index, so every present row is a candidate.

  Reads `authorize?: false`, like every other index access here.
  """
  @spec prunable_source_ids(module(), term()) :: [String.t()]
  def prunable_source_ids(resource, tenant) do
    source_type = Info.source_type(resource)

    resource
    |> Info.index()
    |> Ash.Query.filter(source_type == ^source_type)
    |> exclude_terminal(Info.on_destroy(resource))
    |> Ash.read!(tenant: tenant, authorize?: false)
    |> Enum.map(& &1.source_id)
  end

  defp exclude_terminal(query, :archive), do: Ash.Query.filter(query, archived == false)
  defp exclude_terminal(query, _remove), do: query

  defp indexed_rows(resource, source_id, tenant) do
    source_type = Info.source_type(resource)

    resource
    |> Info.index()
    |> Ash.Query.filter(source_type == ^source_type and source_id == ^source_id)
    |> Ash.read!(tenant: tenant, authorize?: false)
  end

  defp archived_attrs(row) do
    %{
      source_type: row.source_type,
      source_id: row.source_id,
      language: row.language,
      search_text: row.search_text,
      label: row.label,
      archived: true
    }
  end
end
