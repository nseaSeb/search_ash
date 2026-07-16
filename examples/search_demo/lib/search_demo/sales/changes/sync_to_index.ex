defmodule SearchDemo.Sales.Changes.SyncToIndex do
  @moduledoc """
  Reusable change that mirrors a source record into the unified `SearchDemo.Search.Document`
  index. Runs in `after_action` (so the record's id exists) and upserts on
  `(org_id, source_type, source_id)`, carrying the tenant through.

  Options:

    * `:source_type` — string tag stored in the index (e.g. "facture")
    * `:fields` — source attributes whose text is concatenated and stemmed
    * `:label_field` — source attribute used as the human-readable label
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    source_type = Keyword.fetch!(opts, :source_type)
    fields = Keyword.fetch!(opts, :fields)
    label_field = Keyword.fetch!(opts, :label_field)

    Ash.Changeset.after_action(changeset, fn changeset, record ->
      language = Map.fetch!(record, :language)

      text =
        fields
        |> Enum.map(&to_string(Map.get(record, &1) || ""))
        |> Enum.join(" ")

      SearchDemo.Search.upsert_document!(
        %{
          source_type: source_type,
          source_id: to_string(record.id),
          language: language,
          search_text: SearchCore.searchable_text(text, language),
          label: to_string(Map.get(record, label_field))
        },
        tenant: changeset.tenant
      )

      {:ok, record}
    end)
  end
end
