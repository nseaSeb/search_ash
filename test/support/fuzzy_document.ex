defmodule SearchAsh.Test.FuzzyDocument do
  @moduledoc false
  # A `fuzzy? true` index on its own table (trigram matching must not change what the
  # other global-search tests match). Also the only NON-multitenant index in the suite.
  use Ash.Resource,
    domain: SearchAsh.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [SearchAsh.GlobalIndex]

  postgres do
    table "test_fuzzy_documents"
    repo SearchAsh.Test.Repo
  end

  global_index do
    default_language :fr
    fuzzy? true
    # Tighter than the 0.3 the database applies, so an exact reference stops dragging a
    # look-alike one back with it — while still keeping a real typo (measured: 0.44).
    fuzzy_threshold 0.35
    # A caller who asks for no page gets a bounded page instead of the whole index.
    default_limit 5
  end

  attributes do
    uuid_primary_key :id
  end
end
