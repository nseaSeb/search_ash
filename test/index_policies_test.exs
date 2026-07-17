defmodule SearchAsh.IndexPoliciesTest do
  @moduledoc """
  The global index does **not** inherit the policies of the resources feeding it — but
  `:global_search` is a plain Ash read action, so policies on the index resource itself
  compose with it. That is what makes role-to-entity-type visibility possible, and it is
  documented as a supported pattern, so it is pinned here.

  What this cannot do is row-level authorization: an index row carries no owner or team.
  The last test states that boundary so nobody mistakes the guarantee for a stronger one.
  """
  use ExUnit.Case, async: false
  require Ash.Query

  alias SearchAsh.Test.{Domain, Repo, SecuredDocument}

  setup do
    Ecto.Adapters.SQL.query!(
      Repo,
      "TRUNCATE test_products, test_invoices, test_search_documents",
      []
    )

    # One term, two entity types, one index.
    Domain.create_product!(%{name: "Vis inox", sku: "V1"}, tenant: "a")
    Domain.create_invoice!(%{number: "Vis facture 42"}, tenant: "a")
    :ok
  end

  defp search(actor) do
    SecuredDocument
    |> Ash.Query.for_read(:global_search, %{query: "vis", language: :fr})
    |> Ash.read!(tenant: "a", actor: actor, authorize?: true)
    |> Enum.map(& &1.source_type)
    |> Enum.sort()
  end

  test "unauthorized, the index returns every matching entity type" do
    all =
      SecuredDocument
      |> Ash.Query.for_read(:global_search, %{query: "vis", language: :fr})
      |> Ash.read!(tenant: "a", authorize?: false)
      |> Enum.map(& &1.source_type)
      |> Enum.sort()

    assert all == ["invoice", "product"]
  end

  test "a policy on the index filters :global_search by the actor's role" do
    assert search(%{visible_types: ["invoice"]}) == ["invoice"]
    assert search(%{visible_types: ["product"]}) == ["product"]
    assert search(%{visible_types: ["invoice", "product"]}) == ["invoice", "product"]
  end

  test "an actor allowed nothing sees nothing, rather than everything" do
    assert search(%{visible_types: []}) == []
  end

  test "the policy composes with the search filter, it does not replace it" do
    # A term matching only the product: the invoice-only actor gets nothing, and the
    # product-only actor still has to match the query.
    hits =
      SecuredDocument
      |> Ash.Query.for_read(:global_search, %{query: "inox", language: :fr})
      |> Ash.read!(tenant: "a", actor: %{visible_types: ["invoice", "product"]}, authorize?: true)

    assert Enum.map(hits, & &1.source_type) == ["product"]
  end

  test "tenant isolation still applies on top of the policy" do
    Domain.create_product!(%{name: "Vis autre org", sku: "V2"}, tenant: "b")

    hits =
      SecuredDocument
      |> Ash.Query.for_read(:global_search, %{query: "vis", language: :fr})
      |> Ash.read!(tenant: "b", actor: %{visible_types: ["product"]}, authorize?: true)

    assert Enum.map(hits, & &1.label) == ["Vis autre org"]
  end

  test "the boundary: an index row carries nothing to authorize a single row on" do
    # Only these reach an index row, so a policy can key off `source_type` but never off
    # an owner or a team. Row-level visibility needs `search do … end` on the source; what
    # a result exposes is controlled by `label_field`.
    attrs =
      SearchAsh.Source.Document.to_attrs(SearchAsh.Test.Product, %{
        id: "1",
        name: "Vis",
        sku: "V",
        language: :fr,
        discontinued: false
      })

    assert Map.keys(attrs) |> Enum.sort() ==
             [:archived, :label, :language, :search_text, :source_id, :source_type]
  end
end
