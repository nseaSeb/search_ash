# Demo data for the GreenAsh console at /cli. Re-runnable: resets then seeds.
alias Blog.Repo
alias Blog.Search.Document

for schema <- [Document, Blog.Post, Blog.Sales.Facture, Blog.Sales.Client, Blog.Sales.Produit] do
  Repo.delete_all(schema)
end

# --- org_a (French) ---
Blog.Blog.create_post!(
  %{title: "Les chevaux", body: "J'adore regarder les chevaux qui mangent.", language: :french},
  tenant: "org_a"
)

Blog.Sales.create_facture!(
  %{numero: "F-001", client_nom: "Ferme des Chevaux",
    description: "Livraison de foin pour les chevaux."},
  tenant: "org_a"
)

Blog.Sales.create_client!(
  %{nom: "Chevaux & Co", email: "contact@chevaux.fr", notes: "Éleveur de chevaux."},
  tenant: "org_a"
)

Blog.Sales.create_produit!(
  %{reference: "P-42", libelle: "Selle pour cheval", description: "Équipement pour chevaux."},
  tenant: "org_a"
)

Blog.Sales.create_facture!(
  %{numero: "F-002", client_nom: "Boulangerie du coin", description: "Farine et pain."},
  tenant: "org_a"
)

# --- org_b (mixed) ---
Blog.Blog.create_post!(
  %{title: "Running", body: "She was running fast and the connections worked.", language: :english},
  tenant: "org_b"
)

Blog.Sales.create_produit!(
  %{reference: "PB-1", libelle: "Chevaux de bois", description: "Jouet en forme de cheval."},
  tenant: "org_b"
)

IO.puts("Seeded demo data for org_a and org_b (index: #{Repo.aggregate(Document, :count)} documents).")
