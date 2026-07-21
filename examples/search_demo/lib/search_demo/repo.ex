defmodule SearchDemo.Repo do
  # The spike resource doesn't use Ash's Postgres helper functions, so skip installing
  # the "ash-functions" extension (keeps the generated migration focused on our index).
  use AshPostgres.Repo, otp_app: :search_demo, warn_on_missing_ash_functions?: false

  # pg_trgm backs the `fuzzy? true` option on SearchDemo.Search.Document (trigram
  # typo-tolerance on the label). This is the one extension search_ash can ask for,
  # and only when fuzzy is opted into.
  @impl true
  def installed_extensions, do: ["pg_trgm"]

  @impl true
  def min_pg_version, do: %Version{major: 15, minor: 0, patch: 0}
end
