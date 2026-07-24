# Run with:  mix ash_postgres.migrate && mix run global_demo.exs
#
# Option B: a unified, cross-entity, tenant-scoped, ranked global search.
# Two orgs hold look-alike data; each org's search returns ONLY its own rows, ranked
# by relevance, with (source_type, source_id) to link back to the object.

require Ash.Query

alias SearchDemo.Sales
alias SearchDemo.Search
alias SearchDemo.Search.Document
alias SearchDemo.Repo

for schema <- [
      Document,
      SearchDemo.Sales.Ligne,
      SearchDemo.Sales.Facture,
      SearchDemo.Sales.Client,
      SearchDemo.Sales.Produit,
      SearchDemo.Accounts.User
    ] do
  Repo.delete_all(schema)
end

# The index carries its own policies and fails closed: with no actor it returns nothing
# at all (that is the point — a search that returns everything when authorization is
# missing is how data leaks). An :admin may find every entity type.
admin = SearchDemo.Accounts.create_user!(%{nom: "demo-admin", role: :admin}, tenant: "org_a")

support =
  SearchDemo.Accounts.create_user!(%{nom: "demo-support", role: :support}, tenant: "org_a")

# --- org_a : several cheval-related records (+ one unrelated) ---
Sales.create_facture!(
  %{
    numero: "F-001",
    client_nom: "Ferme des Chevaux",
    description: "Livraison de foin pour les chevaux ; un cheval de trait supplémentaire.",
    tags: ["fournisseur"],
    montant: Decimal.new("80.00")
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
  %{
    numero: "F-002",
    client_nom: "Boulangerie du coin",
    description: "Farine et pain.",
    date_emission: ~D[2026-07-21],
    statut: :envoyee,
    tags: ["export", "urgent"],
    montant: Decimal.new("480.50")
  },
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
      "  tier #{d.label_match_tier}  #{Float.round(d.search_rank, 4)}  " <>
        "#{String.pad_trailing(d.source_type, 8)} #{d.label}  " <>
        "(org=#{d.org_id}, id=#{String.slice(d.source_id, 0, 8)}…)"
    )
  end)

  IO.puts("")
end

search = fn query, tenant, actor ->
  Search.global_search!(query, :fr, tenant: tenant, actor: actor)
end

a = search.("chevaux", "org_a", admin)
b = search.("chevaux", "org_b", admin)

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

# Ranking is composite since 0.4.0: the *label* tier first (0 exact, 1 starts-with,
# 2 contains, 3 body-only), then ts_rank inside a tier. "Chevaux & Co" is what the
# user typed, so it beats a facture whose body merely says "cheval" more often.
check.(
  "ranked by label tier, then ts_rank",
  a == Enum.sort_by(a, &{&1.label_match_tier, -&1.search_rank})
)

check.("the client named 'Chevaux & Co' ranks first", hd(a).label == "Chevaux & Co")

check.(
  "every result carries (source_type, source_id) to link the object",
  Enum.all?(a, &(&1.source_type != nil and &1.source_id != nil))
)

# --- authorization: the index does not inherit the sources' policies, it has its own ---
check.(
  "no actor -> nothing at all (the policies fail closed)",
  match?({:error, _}, Search.global_search("chevaux", :fr, tenant: "org_a"))
)

support_types = search.("chevaux", "org_a", support) |> Enum.map(& &1.source_type) |> Enum.uniq()
check.(":support finds clients only, :admin finds all 3 types", support_types == ["client"])

# --- 0.4.0: what a results page needs ---
IO.puts("")

# Typo tolerance (`fuzzy? true` + pg_trgm): a misspelt label still finds the client.
# "chevaus" (une lettre fautive) score 0.50 ; "chevo" ne scorerait que 0.333 — une
# troncature n'est pas une faute de frappe, et le seuil 0.35 l'écarte volontairement.
check.(
  "fuzzy: \"chevaus\" still finds 'Chevaux & Co'",
  "Chevaux & Co" in Enum.map(search.("chevaus", "org_a", admin), & &1.label)
)

# Text from related records (`load` + `extra_text`): a facture is found by its lines.
ligne_facture =
  Sales.create_facture!(%{numero: "F-003", client_nom: "Primeur", description: "Livraison"},
    tenant: "org_a"
  )

Sales.create_ligne!(%{facture_id: ligne_facture.id, designation: "Tomates anciennes"},
  tenant: "org_a"
)

SearchAsh.reindex_one(SearchDemo.Sales.Facture, ligne_facture.id, tenant: "org_a")

tomates = search.("tomates", "org_a", admin)

check.(
  "extra_text: \"tomates\" finds F-003 through its ligne",
  Enum.map(tomates, & &1.label) == ["F-003"]
)

check.("excerpt is stored for display", hd(tomates).excerpt =~ "Tomates anciennes")

# Tags : un tableau, présent sur les DEUX chemins — et ce n'est pas redondant.
check.(
  "tags en plein texte : taper \"export\" trouve la facture",
  "F-002" in Enum.map(search.("export", "org_a", admin), & &1.label)
)

par_tag =
  Document
  |> Ash.Query.for_read(:global_search, %{query: ""})
  |> Ash.Query.set_tenant("org_a")
  |> Ash.Query.filter(has(tags, "urgent"))
  |> Ash.read!(actor: admin)

check.(
  "tags en filtre : has(tags, \"urgent\") garde F-002 et EXCLUT F-001, qui a un autre tag",
  Enum.map(par_tag, & &1.label) == ["F-002"] and
    "fournisseur" in (Enum.find(search.("chevaux", "org_a", admin), &(&1.label == "F-001")) ||
                        %{tags: []}).tags
)

# Montant : un numérique, filtre d'intervalle et tri.
gros =
  Document
  |> Ash.Query.for_read(:global_search, %{query: ""})
  |> Ash.Query.set_tenant("org_a")
  |> Ash.Query.filter(montant > 100)
  |> Ash.read!(actor: admin)

# F-001 est à 80, F-002 à 480,50 : le seuil passe entre les deux, donc un filtre
# neutralisé se ferait prendre.
check.(
  "montant > 100 : garde F-002 (480,50) et écarte F-001 (80)",
  Enum.map(gros, & &1.label) == ["F-002"]
)

IO.puts("")

# Les TROIS types d'index, sur une même ligne : texte analysé (fields -> search_text),
# keyword (statut, stocké brut pour un filtre exact) et date (document_date).
statuts =
  Document
  |> Ash.Query.for_read(:global_search, %{query: ""})
  |> Ash.Query.set_tenant("org_a")
  |> Ash.Query.filter(statut == "envoyee")
  |> Ash.read!(actor: admin)

check.(
  "keyword : filtre exact sur statut == \"envoyee\"",
  Enum.map(statuts, & &1.label) == ["F-002"]
)

# Les trois types combinés dans une seule requête : mot cherché + keyword + intervalle.
combine =
  Document
  |> Ash.Query.for_read(:global_search, %{query: "farine"})
  |> Ash.Query.set_tenant("org_a")
  |> Ash.Query.filter(statut == "envoyee" and document_date >= ^~D[2026-07-01])
  |> Ash.read!(actor: admin)

check.(
  "texte + keyword + date dans une seule requête",
  Enum.map(combine, & &1.label) == ["F-002"]
)

# 0.5.0 — dates: a typed column to filter and sort on, and the date in words for the
# search box. Two different needs, two mechanisms, both fed from the same record.
juin =
  Sales.create_facture!(
    %{numero: "F-JUIN", client_nom: "Ferme", description: "Foin", date_emission: ~D[2026-06-15]},
    tenant: "org_a"
  )

Sales.create_facture!(
  %{numero: "F-DEC", client_nom: "Ferme", description: "Foin", date_emission: ~D[2026-12-01]},
  tenant: "org_a"
)

check.(
  "dates en toutes lettres : \"juin\" trouve F-JUIN",
  Enum.map(search.("juin", "org_a", admin), & &1.label) == ["F-JUIN"]
)

recent =
  Document
  |> Ash.Query.for_read(:global_search, %{query: "foin"})
  |> Ash.Query.set_tenant("org_a")
  |> Ash.Query.unset([:sort])
  # `:desc_nils_last`, pas `:desc` : F-001 n'a pas de date, et Postgres remonte les NULL
  # en TÊTE d'un tri décroissant — le piège d'une colonne qu'une source ne remplit pas.
  |> Ash.Query.sort(document_date: :desc_nils_last)
  |> Ash.read!(actor: admin)

check.(
  "colonne date typée : du plus récent au plus ancien, sans date en dernier",
  Enum.map(recent, & &1.label) == ["F-DEC", "F-JUIN", "F-001"]
)

apres_juillet =
  Document
  |> Ash.Query.for_read(:global_search, %{query: ""})
  |> Ash.Query.set_tenant("org_a")
  |> Ash.Query.filter(document_date >= ^~D[2026-07-01])
  |> Ash.read!(actor: admin)

check.(
  "un seul axe de date, alimenté par des attributs différents selon le type",
  Enum.map(apres_juillet, & &1.source_type) |> Enum.uniq() |> Enum.sort() == [
    "client",
    "facture",
    "produit"
  ]
)

# 0.5.0 — pondération : un match dans le numéro pèse plus que dans le corps.
[f_juin] = search.("f-juin", "org_a", admin)
check.("search_text stocke un tsvector pondéré", f_juin.search_text =~ ~r/:\d+A/)

_ = juin

# 0.5.0 — synonymes : une abréviation tapée dans la barre atteint les mots qu'elle désigne,
# par expansion à la REQUÊTE (un ajout au dictionnaire prend effet sans reindex). `bl` n'est
# un token stocké nulle part ; seul le synonyme `bon de livraison` l'y mène — et comme la
# valeur multi-mots devient l'AND-group `(bon & livraison)`, une facture qui ne dit QUE
# "livraison" (F-001) n'est volontairement pas prise.
Sales.create_facture!(
  %{
    numero: "F-777",
    client_nom: "Transporteur",
    description: "Bon de livraison signé à la réception."
  },
  tenant: "org_a"
)

Sales.create_facture!(
  %{numero: "F-888", client_nom: "Atelier", description: "Commande urgente à préparer."},
  tenant: "org_a"
)

check.(
  ~s|synonyme multi-mots : "bl" trouve la facture disant "bon de livraison"|,
  Enum.map(search.("bl", "org_a", admin), & &1.label) == ["F-777"]
)

check.(
  ~s|précision de l'AND-group : "bl" n'attrape PAS F-001, qui ne dit que "livraison"|,
  "F-001" not in Enum.map(search.("bl", "org_a", admin), & &1.label)
)

check.(
  ~s|synonyme mono-token : "cde" trouve la facture disant "commande"|,
  Enum.map(search.("cde", "org_a", admin), & &1.label) == ["F-888"]
)

# Tab badges, without a second search.
counts = SearchAsh.counts_by_type(Document, "chevaux", tenant: "org_a", actor: admin)
IO.puts("\ncounts_by_type(\"chevaux\") -> #{inspect(counts)}")
check.("counts_by_type matches the result set", Enum.sum(Map.values(counts)) == length(a))

# Pagination, with a total for the header.
page =
  Document
  |> Ash.Query.for_read(:global_search, %{query: "chevaux"})
  |> Ash.Query.set_tenant("org_a")
  |> Ash.read!(actor: admin, page: [limit: 2, offset: 0, count: true])

check.(
  "pagination: page 1 of #{page.count} results holds 2",
  length(page.results) == 2 and page.count == 3
)

IO.puts("")

# --- deletion: destroying a source object removes it from the index ---
Sales.destroy_produit!(produit_a, tenant: "org_a")
a_after = search.("chevaux", "org_a", admin)

IO.puts("")
show.(~s|after destroying produit "Selle pour cheval" — org_a:|, a_after)

check.(
  "destroyed produit is gone from the index",
  "Selle pour cheval" not in Enum.map(a_after, & &1.label)
)

check.("the other 2 docs remain", length(a_after) == 2)

# --- réconciliation : ce qui arrive quand une écriture ne passe PAS par Ash ---
#
# L'indexation est une `Ash.Resource.Change` : elle ne se déclenche que lorsque Ash
# construit un changeset. Un `Repo.query!` brut, une cascade SQL, une restauration depuis
# une corbeille — rien de tout cela ne la réveille, et l'index garde l'ancien état sans
# qu'aucun signal ne l'indique. D'où les deux fonctions ci-dessous.

IO.puts("")

# 1. reindex/2 — backfiller de l'existant. C'est le premier geste quand on adopte la lib
#    sur une base déjà remplie : ici on insère en SQL pur, donc la sync ne voit rien.
Repo.query!("""
INSERT INTO factures (id, org_id, numero, client_nom, description, language, statut, inserted_at, updated_at)
VALUES (gen_random_uuid(), 'org_a', 'F-LEGACY', 'Client historique', 'Ancienne facture',
        'fr', 'payee', now(), now())
""")

check.(
  "avant reindex : la facture insérée en SQL est introuvable",
  search.("historique", "org_a", admin) == []
)

SearchAsh.reindex(Sales.Facture, tenant: "org_a")

check.(
  "reindex/2 : elle devient trouvable",
  Enum.map(search.("historique", "org_a", admin), & &1.label) == ["F-LEGACY"]
)

# 2. prune/2 — balayer les orphelins. On supprime la source en SQL pur : la ligne d'index
#    survit et continue de remonter dans les résultats, en pointant vers un objet disparu.
Repo.query!("DELETE FROM factures WHERE numero = 'F-LEGACY'")

check.(
  "après un DELETE brut : l'index garde un orphelin (il pointe dans le vide)",
  Enum.map(search.("historique", "org_a", admin), & &1.label) == ["F-LEGACY"]
)

supprimees = SearchAsh.prune(Sales.Facture, tenant: "org_a")

check.(
  "prune/2 : l'orphelin est balayé, et le compte est rendu (#{supprimees})",
  supprimees == 1 and search.("historique", "org_a", admin) == []
)

# Le compte renvoyé par prune/2 est aussi une métrique de dérive : sur une base saine il
# vaut 0. S'il ne l'est pas, c'est qu'une écriture contourne Ash quelque part.
check.(
  "sur une base saine, prune/2 ne trouve plus rien",
  SearchAsh.prune(Sales.Facture, tenant: "org_a") == 0
)

IO.puts("")

IO.puts("EXPLAIN (index usage + tenant filter):")

# A plan is only meaningful at a scale where the planner has a real choice: over five
# rows a sequential scan genuinely beats a GIN probe, and the demo would "prove" the
# index by showing one that is never used. So pad org_a with synthetic filler first —
# inserted straight in SQL (this is throwaway noise, not domain data), then ANALYZE so
# the planner sees it. Note the values: since 0.5.0 the column holds a tsvector *literal*,
# and the query casts it rather than calling `to_tsvector` — hand-written SQL has to
# follow, or it silently stops using the index.
Repo.query!("""
INSERT INTO search_documents (id, org_id, source_type, source_id, language, search_text, label, archived)
SELECT gen_random_uuid(), 'org_a', 'produit', 'filler-' || i, 'fr',
       '''article'':1 ''divers'':2 ''reference'':3 ''' || i || ''':4', 'Filler ' || i, false
FROM generate_series(1, 5000) AS i
""")

Repo.query!("ANALYZE search_documents")

%{rows: rows} =
  Repo.query!("""
  EXPLAIN SELECT source_type, source_id,
                 ts_rank(search_text::tsvector, to_tsquery('simple', 'cheval')) AS rank
  FROM search_documents
  WHERE org_id = 'org_a'
    AND search_text::tsvector @@ to_tsquery('simple', 'cheval')
  ORDER BY rank DESC
  """)

Enum.each(rows, fn [line] -> IO.puts("  " <> line) end)

# Le plan ci-dessus est celui que Postgres choisit VRAIMENT a cette taille — et un
# balayage sequentiel y est souvent le bon choix. Ce qui doit etre verifie, c'est que
# l'index reste UTILISABLE : que son expression et celle de la requete correspondent
# toujours. On le demande au planner en lui retirant le seq scan.
{:ok, forced} =
  Repo.transaction(fn ->
    Repo.query!("SET LOCAL enable_seqscan = off")

    %{rows: rows} =
      Repo.query!(
        "EXPLAIN SELECT id FROM search_documents " <>
          "WHERE search_text::tsvector @@ to_tsquery('simple', 'cheval')"
      )

    Enum.map_join(rows, "\n", fn [line] -> line end)
  end)

check.(
  "l'index GIN reste utilisable pour la requete (expressions identiques)",
  forced =~ "search_documents_search_idx"
)

Repo.query!("DELETE FROM search_documents WHERE source_id LIKE 'filler-%'")
