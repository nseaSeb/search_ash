defmodule SearchAsh.Test.Contact do
  @moduledoc false
  # Feeds the fuzzy index: label-driven rows (`Dupont`, `BL-2024-0012`) that the
  # trigram/substring match is about.
  use Ash.Resource,
    domain: SearchAsh.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [SearchAsh.Source]

  postgres do
    table "test_contacts"
    repo SearchAsh.Test.Repo
  end

  searchable do
    index SearchAsh.Test.FuzzyDocument
    source_type :contact
    fields [:name, :ref]
    language_attribute :language
    label_field :name
  end

  actions do
    defaults [:read]

    create :create do
      accept [:name, :ref, :language]
    end

    update :update do
      accept [:name, :ref, :language]
    end

    destroy :destroy do
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
    attribute :ref, :string, public?: true

    attribute :language, :atom,
      allow_nil?: false,
      public?: true,
      default: :fr,
      constraints: [one_of: SearchCore.Language.supported_languages()]
  end
end
