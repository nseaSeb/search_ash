# Run with:  mix ash_postgres.migrate && mix run demo.exs
#
# Exercises the full Ash flow on the SearchAsh-powered resource: create (generated
# change fills search_text), the generated :search action, per-row languages AND
# per-tenant isolation — all against real Postgres.

require Ash.Query
alias Blog.{Post, Repo}

Repo.delete_all(Post)

# org_a and org_b both have a French document about "chevaux"; tenant scoping must keep
# them apart even though they'd match the same tsquery.
posts = [
  {"org_a", %{language: :french, title: "Les chevaux",
              body: "J'adore regarder les chevaux qui mangent dans les prés."}},
  {"org_a", %{language: :french, title: "Cuisine",
              body: "Une recette de poissons grillés avec des herbes."}},
  {"org_b", %{language: :french, title: "Chevaux de course",
              body: "Les chevaux de course les plus rapides du monde."}},
  {"org_b", %{language: :english, title: "Running",
              body: "She was running fast and the connections finally worked."}}
]

for {org, attrs} <- posts, do: Blog.Blog.create_post!(attrs, tenant: org)

IO.puts("Seeded #{Repo.aggregate(Post, :count)} posts across 2 orgs.\n")

check = fn label, results, expected ->
  got = results |> Enum.map(& &1.title) |> Enum.sort()
  status = if got == Enum.sort(expected), do: "OK  ", else: "FAIL"
  IO.puts("[#{status}] #{label} -> #{inspect(got)}")
  if got != Enum.sort(expected), do: IO.puts("        expected #{inspect(Enum.sort(expected))}")
end

# Per-row language (both tenants) + stemming symmetry ("chevaux" -> "cheval").
check.(~s|org_a FR "chevaux"|,
  Blog.Blog.search_posts!("chevaux", :french, tenant: "org_a"), ["Les chevaux"])

check.(~s|org_a FR "poisson grillé"|,
  Blog.Blog.search_posts!("poisson grillé", :french, tenant: "org_a"), ["Cuisine"])

check.(~s|org_b EN "connection"|,
  Blog.Blog.search_posts!("connection", :english, tenant: "org_b"), ["Running"])

# Tenant isolation: the SAME query+language in each org returns only that org's rows.
check.(~s|org_b FR "chevaux" (isolation)|,
  Blog.Blog.search_posts!("chevaux", :french, tenant: "org_b"), ["Chevaux de course"])

check.(~s|org_a cannot see org_b "connection"|,
  Blog.Blog.search_posts!("connection", :english, tenant: "org_a"), [])

# Confirm the generated change stemmed at write time.
post =
  Post
  |> Ash.Query.filter(title == "Les chevaux")
  |> Ash.read_one!(tenant: "org_a")

IO.puts(~s|\nStored search_text for "Les chevaux": #{inspect(post.search_text)}|)

IO.puts("\nEXPLAIN (index usage):")

%{rows: rows} =
  Repo.query!("""
  EXPLAIN SELECT * FROM posts
  WHERE org_id = 'org_a'
    AND to_tsvector('simple', search_text) @@ to_tsquery('simple', 'cheval')
  """)

Enum.each(rows, fn [line] -> IO.puts("  " <> line) end)
