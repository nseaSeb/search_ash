defmodule SearchAsh.Test.SynonymMfaArticle do
  @moduledoc false
  # Exercises the `{module, function}` form of the per-resource `search do synonyms … end`
  # option (mirror of SynonymMfaDocument on the GlobalIndex side). Never seeded or queried —
  # only `SearchAsh.Info.synonyms/2` reads its DSL — so it needs no table.
  use Ash.Resource,
    domain: SearchAsh.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [SearchAsh]

  postgres do
    table "test_synonym_mfa_articles"
    repo SearchAsh.Test.Repo
  end

  search do
    fields [:title]
    language_attribute :language
    synonyms {SearchAsh.Test.Synonyms, :for_language}
  end

  actions do
    defaults [:read]
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true

    attribute :language, :atom,
      allow_nil?: false,
      public?: true,
      default: :fr,
      constraints: [one_of: SearchCore.Language.supported_languages()]
  end
end
