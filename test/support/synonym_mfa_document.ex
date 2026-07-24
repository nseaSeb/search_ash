defmodule SearchAsh.Test.SynonymMfaDocument do
  @moduledoc false
  # Exercises the `{module, function}` form of `global_index`'s `synonyms` option (the
  # deploy-free, domain-expert-editable path). Never seeded or queried — only
  # `SearchAsh.GlobalIndex.Info.synonyms/2` reads its DSL — so it needs no table.
  use Ash.Resource,
    domain: SearchAsh.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [SearchAsh.GlobalIndex]

  postgres do
    table "test_synonym_mfa_documents"
    repo SearchAsh.Test.Repo
  end

  global_index do
    default_language :fr
    synonyms {SearchAsh.Test.Synonyms, :for_language}
  end

  attributes do
    uuid_primary_key :id
  end
end
