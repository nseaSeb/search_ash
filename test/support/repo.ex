defmodule SearchAsh.Test.Repo do
  @moduledoc false
  use AshPostgres.Repo, otp_app: :search_ash, warn_on_missing_ash_functions?: false

  @impl true
  def installed_extensions, do: []

  @impl true
  def min_pg_version, do: %Version{major: 15, minor: 0, patch: 0}
end
