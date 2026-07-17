defmodule SearchAsh.LabelFieldSyncTest do
  @moduledoc """
  Regression: a change to `label_field` must re-sync the index even when `label_field` is not
  one of the searchable `fields`.

  The sync's `recompute?` short-circuit skips the stemmer when no *watched* attribute changed.
  It used to watch only `fields ++ language ++ archived` — not `label_field` — so renaming the
  label of a resource whose `label_field` sits outside `fields` changed nothing watched, no
  upsert ran, and the index kept the stale label. Every other fixture hides this by including
  `label_field` in `fields`.
  """
  use ExUnit.Case, async: false

  alias SearchAsh.Test.{Domain, Repo, SearchDocument}

  setup do
    Ecto.Adapters.SQL.query!(Repo, "TRUNCATE test_tickets, test_search_documents", [])
    :ok
  end

  defp label_of(source_id) do
    SearchDocument
    |> Ash.read!(authorize?: false)
    |> Enum.find(&(&1.source_id == source_id))
    |> Map.get(:label)
  end

  test "updating only label_field (outside fields) refreshes the index label" do
    ticket =
      Domain.create_ticket!(%{subject: "Imprimante en panne", body: "bourrage papier"},
        tenant: "a"
      )

    assert label_of(ticket.id) == "Imprimante en panne"

    # A normal Ash update touching only the label — not any searchable field.
    Domain.update_ticket!(ticket, %{subject: "Imprimante réparée"}, tenant: "a")

    assert label_of(ticket.id) == "Imprimante réparée"
  end

  test "updating an unrelated-to-index nothing still leaves the label intact" do
    # Guard against over-correction: a body change (a watched field) already re-syncs, and must
    # keep the current label rather than dropping it.
    ticket =
      Domain.create_ticket!(%{subject: "Imprimante en panne", body: "bourrage papier"},
        tenant: "a"
      )

    Domain.update_ticket!(ticket, %{body: "plus de toner"}, tenant: "a")

    assert label_of(ticket.id) == "Imprimante en panne"
  end
end
