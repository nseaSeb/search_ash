# Run with:  mix ash_postgres.migrate && mix run global_demo.exs
#
# Option B: a unified, cross-entity, tenant-scoped, ranked global search.
# Two orgs hold look-alike data; each org's search returns ONLY its own rows, ranked
# by relevance, with (source_type, source_id) to link back to the object.

alias SearchDemo.Sales
alias SearchDemo.Search
alias SearchDemo.Search.Document
alias SearchDemo.Repo

for schema <- [
      Document,
      SearchDemo.Sales.Facture,
      SearchDemo.Sales.Client,
      SearchDemo.Sales.Produit
    ] do
  Repo.delete_all(schema)
end

# --- org_a : several cheval-related records (+ one unrelated) ---
Sales.create_facture!(
  %{
    numero: "F-001",
    client_nom: "Ferme des Chevaux",
    description: "Livraison de foin pour les chevaux ; un cheval de trait supplémentaire."
  },
  tenant: "org_a"
)

Sales.create_client!(
  %{nom: "Chevaux & Co", notes: "Éleveur de chevaux de course."},
  tenant: "org_a"
)

produit_a =
  Sales.create_produit!(
    %{reference: "P-42", libelle: "Selle pour cheval", description: "Équipement pour chevaux."},
    tenant: "org_a"
  )

Sales.create_facture!(
  %{numero: "F-002", client_nom: "Boulangerie du coin", description: "Farine et pain."},
  tenant: "org_a"
)

# --- org_b : a cheval-related record that must NEVER surface for org_a ---
Sales.create_produit!(
  %{reference: "PB-1", libelle: "Chevaux de bois", description: "Jouet en forme de cheval."},
  tenant: "org_b"
)

IO.puts("Seeded index: #{Repo.aggregate(Document, :count)} documents across 2 orgs.\n")

show = fn label, results ->
  IO.puts(label)

  Enum.each(results, fn d ->
    IO.puts(
      "  #{Float.round(d.rank, 4)}  #{String.pad_trailing(d.source_type, 8)} " <>
        "#{d.label}  (org=#{d.org_id}, id=#{String.slice(d.source_id, 0, 8)}…)"
    )
  end)

  IO.puts("")
end

a = Search.global_search!("chevaux", :french, tenant: "org_a")
b = Search.global_search!("chevaux", :french, tenant: "org_b")

show.(~s|global_search "chevaux" @ org_a:|, a)
show.(~s|global_search "chevaux" @ org_b:|, b)

check = fn label, cond -> IO.puts("[#{if cond, do: "OK  ", else: "FAIL"}] #{label}") end

check.("org_a returns 3 cheval docs (facture, client, produit)", length(a) == 3)
check.("org_a results are ALL tenant org_a", Enum.all?(a, &(&1.org_id == "org_a")))
check.("unrelated F-002 is absent", "F-002" not in Enum.map(a, & &1.label))

check.(
  "org_b's 'Chevaux de bois' never leaks into org_a",
  "Chevaux de bois" not in Enum.map(a, & &1.label)
)

check.("org_b returns only its own 1 doc", length(b) == 1 and hd(b).org_id == "org_b")
check.("results are ranked (rank descending)", a == Enum.sort_by(a, & &1.rank, :desc))

check.(
  "every result carries (source_type, source_id) to link the object",
  Enum.all?(a, &(&1.source_type != nil and &1.source_id != nil))
)

# --- deletion: destroying a source object removes it from the index ---
Sales.destroy_produit!(produit_a, tenant: "org_a")
a_after = Search.global_search!("chevaux", :french, tenant: "org_a")

IO.puts("")
show.(~s|after destroying produit "Selle pour cheval" — org_a:|, a_after)

check.(
  "destroyed produit is gone from the index",
  "Selle pour cheval" not in Enum.map(a_after, & &1.label)
)

check.("the other 2 docs remain", length(a_after) == 2)

IO.puts("EXPLAIN (index usage + tenant filter):")

%{rows: rows} =
  Repo.query!("""
  EXPLAIN SELECT source_type, source_id,
                 ts_rank(to_tsvector('simple', search_text), to_tsquery('simple', 'cheval')) AS rank
  FROM search_documents
  WHERE org_id = 'org_a'
    AND to_tsvector('simple', search_text) @@ to_tsquery('simple', 'cheval')
  ORDER BY rank DESC
  """)

Enum.each(rows, fn [line] -> IO.puts("  " <> line) end)
