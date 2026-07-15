defmodule Blog.Repo do
  # The spike resource doesn't use Ash's Postgres helper functions, so skip installing
  # the "ash-functions" extension (keeps the generated migration focused on our index).
  use AshPostgres.Repo, otp_app: :blog, warn_on_missing_ash_functions?: false

  @impl true
  def installed_extensions, do: []

  @impl true
  def min_pg_version, do: %Version{major: 15, minor: 0, patch: 0}
end
