defmodule SearchAsh.IndexPoliciesTest do
  @moduledoc """
  The global index does **not** inherit the policies of the resources feeding it — but
  `:global_search` is a plain Ash read action, so policies on the index resource itself
  compose with it. That is what makes role-to-entity-type visibility possible, and it is
  documented as a supported pattern, so it is pinned here.

  The second half matters just as much: `SearchAsh.Source`'s own mirroring must keep
  working when an index carries policies. It reads and writes the index internally with no
  actor, so without `authorize?: false` a policied index broke every destroy — while the
  documentation was telling people to add exactly those policies.
  """
  use ExUnit.Case, async: false
  require Ash.Query

  alias SearchAsh.Test.{Domain, Repo, SecuredDocument, SecuredProduct}

  setup do
    Ecto.Adapters.SQL.query!(
      Repo,
      "TRUNCATE test_secured_products, test_secured_invoices, test_secured_documents",
      []
    )

    # One term, two entity types, one policied index.
    Domain.create_secured_product!(%{name: "Vis inox"}, tenant: "a")
    Domain.create_secured_invoice!(%{number: "Vis facture 42"}, tenant: "a")
    :ok
  end

  defp search(actor, query \\ "vis", tenant \\ "a") do
    SecuredDocument
    |> Ash.Query.for_read(:global_search, %{query: query, language: :fr})
    |> Ash.read!(tenant: tenant, actor: actor, authorize?: true)
  end

  defp types(results), do: results |> Enum.map(& &1.source_type) |> Enum.sort()

  describe "policies on the index filter :global_search" do
    test "unauthorized, the index returns every matching entity type" do
      all =
        SecuredDocument
        |> Ash.Query.for_read(:global_search, %{query: "vis", language: :fr})
        |> Ash.read!(tenant: "a", authorize?: false)

      assert types(all) == ["invoice", "product"]
    end

    test "a policy filters by the actor's role" do
      assert types(search(%{visible_types: ["invoice"]})) == ["invoice"]
      assert types(search(%{visible_types: ["product"]})) == ["product"]
      assert types(search(%{visible_types: ["invoice", "product"]})) == ["invoice", "product"]
    end

    test "an actor allowed nothing sees nothing, rather than everything" do
      assert search(%{visible_types: []}) == []
    end

    test "the policy narrows the search, it does not replace it" do
      assert types(search(%{visible_types: ["invoice", "product"]}, "inox")) == ["product"]
      assert search(%{visible_types: ["invoice", "product"]}, "inexistant") == []
    end

    test "tenant isolation still applies on top of the policy" do
      Domain.create_secured_product!(%{name: "Vis autre org"}, tenant: "b")

      assert Enum.map(search(%{visible_types: ["product"]}, "vis", "b"), & &1.label) ==
               ["Vis autre org"]
    end
  end

  describe "policies on the index do not break SearchAsh.Source's machinery" do
    # Regression: sync/remove read and wrote the index with no actor and no
    # `authorize?: false`, so a policied index made every destroy raise Forbidden.
    # Mirroring is machinery — the source write was already authorized by the source's own
    # policies, and the index's policies answer a different question (what may a user
    # *find*).

    test "creating a source indexes it" do
      assert Repo.aggregate(SecuredDocument, :count) == 2
    end

    test "destroying a source removes its index row" do
      [product] = Ash.read!(SecuredProduct, tenant: "a")
      Domain.destroy_secured_product!(product, tenant: "a")

      assert Repo.aggregate(SecuredDocument, :count) == 1
      assert search(%{visible_types: ["product"]}) == []
    end

    test "reindex/2 backfills" do
      Ecto.Adapters.SQL.query!(Repo, "TRUNCATE test_secured_documents", [])
      assert Repo.aggregate(SecuredDocument, :count) == 0

      SearchAsh.reindex(SecuredProduct, tenant: "a")

      assert Repo.aggregate(SecuredDocument, :count) == 1
    end
  end

  test "the boundary: an index row carries nothing to authorize a single row on" do
    # Only these reach an index row, so a policy can key off `source_type` but never off
    # an owner or a team. Row-level visibility needs `search do … end` on the source; what
    # a result exposes is controlled by `label_field`.
    attrs = SearchAsh.Source.Document.to_attrs(SecuredProduct, %{id: "1", name: "Vis"})

    assert Enum.sort(Map.keys(attrs)) ==
             [:archived, :label, :language, :search_text, :source_id, :source_type]
  end
end
