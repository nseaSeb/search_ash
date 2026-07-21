# Demo data for the GreenAsh console at /cli. Re-runnable: resets then seeds.
alias SearchDemo.Repo
alias SearchDemo.Search.Document

for schema <- [
      Document,
      SearchDemo.Post,
      SearchDemo.Sales.Ligne,
      SearchDemo.Sales.Facture,
      SearchDemo.Sales.Client,
      SearchDemo.Sales.Produit,
      SearchDemo.Accounts.User
    ] do
  Repo.delete_all(schema)
end

# --- users: the index fails closed, so the console needs an actor to find anything ---
# `:actor user <id>` in the GreenAsh console reads as one of these; the same query
# returns different rows per role (admin: everything, commercial: factures+clients,
# support: clients).
for role <- [:admin, :commercial, :support], org <- ["org_a", "org_b"] do
  SearchDemo.Accounts.create_user!(%{nom: "#{role}-#{org}", role: role}, tenant: org)
end

# --- org_a (French) ---
SearchDemo.Blog.create_post!(
  %{title: "Les chevaux", body: "J'adore regarder les chevaux qui mangent.", language: :fr},
  tenant: "org_a"
)

SearchDemo.Sales.create_facture!(
  %{numero: "F-001", client_nom: "Ferme des Chevaux",
    description: "Livraison de foin pour les chevaux.",
    date_emission: ~D[2026-06-15], statut: :payee,
    tags: ["urgent", "fournisseur"], montant: Decimal.new("1250.00")},
  tenant: "org_a"
)

SearchDemo.Sales.create_client!(
  %{nom: "Chevaux & Co", email: "contact@chevaux.fr", notes: "Éleveur de chevaux."},
  tenant: "org_a"
)

SearchDemo.Sales.create_produit!(
  %{reference: "P-42", libelle: "Selle pour cheval", description: "Équipement pour chevaux."},
  tenant: "org_a"
)

facture_lignes =
  SearchDemo.Sales.create_facture!(
    %{numero: "F-002", client_nom: "Boulangerie du coin", description: "Farine et pain.",
      date_emission: ~D[2026-07-21], statut: :envoyee,
      tags: ["export"], montant: Decimal.new("480.50")},
    tenant: "org_a"
  )

# Lines are indexed into the facture's document via `load` + `extra_text`, so
# "tomates" finds F-002 even though the word appears on no facture attribute.
for designation <- ["Tomates anciennes 2kg", "Salades croquantes"] do
  SearchDemo.Sales.create_ligne!(%{facture_id: facture_lignes.id, designation: designation},
    tenant: "org_a"
  )
end

# The lines were created after the facture's own sync, so reconcile it once — exactly
# what the staleness contract prescribes.
SearchAsh.reindex_one(SearchDemo.Sales.Facture, facture_lignes.id, tenant: "org_a")

# --- org_b (mixed) ---
SearchDemo.Blog.create_post!(
  %{title: "Running", body: "She was running fast and the connections worked.", language: :en},
  tenant: "org_b"
)

SearchDemo.Sales.create_produit!(
  %{reference: "PB-1", libelle: "Chevaux de bois", description: "Jouet en forme de cheval."},
  tenant: "org_b"
)

IO.puts("Seeded demo data for org_a and org_b (index: #{Repo.aggregate(Document, :count)} documents).")
