defmodule SearchDemo.Sales.Facture do
  @moduledoc "A demo source entity. On create it mirrors itself into the search index."
  use Ash.Resource,
    otp_app: :search_demo,
    domain: SearchDemo.Sales,
    data_layer: AshPostgres.DataLayer,
    extensions: [SearchAsh.Source]

  postgres do
    table "factures"
    repo SearchDemo.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? true
  end

  searchable do
    index SearchDemo.Search.Document
    source_type :facture
    fields [:numero, :client_nom, :description]
    label_field :numero
    # Index the lines too ("which factures mention tomatoes?"): `load` makes the
    # relationship available, `extra_text` derives text from it. A direct write to a
    # Ligne does NOT re-index this facture — see SearchDemo.Sales.Ligne.
    load [:lignes]

    # The lines' text, plus the date spelled out — so "juillet" in the search box finds
    # the factures of that month. The pipeline stems both sides identically, so it needs
    # no special support: it is just more text. Formatting stays yours (here a plain
    # French month table; plug your CLDR backend in a real app).
    # Deux contributions dérivées, deux classes : les lignes sont du corps de texte, la
    # date en toutes lettres pèse plus.
    extra_text fn facture -> Enum.map(facture.lignes, & &1.designation) end
    extra_text &SearchDemo.Sales.Facture.date_words/1, weight: :c

    # A hit in the number outranks one in the client name, which outranks the body.
    weights %{numero: :a, client_nom: :b}

    # A real date column on the index: filter by range, sort by it. Derived from the
    # record, so it is rewritten on every write and cannot go stale.
    index_attribute :document_date, :date_emission
    index_attribute :statut, :statut

    # Store a raw excerpt for the results page.
    excerpt_length 160
  end

  @months ~w(janvier février mars avril mai juin juillet août septembre octobre novembre décembre)

  @doc "The date written out, so a search box query like \"juillet\" finds it."
  def date_words(%{date_emission: %Date{} = date}) do
    "#{date.day} #{Enum.at(@months, date.month - 1)} #{date.year}"
  end

  def date_words(_), do: ""

  actions do
    defaults [:read]

    create :create do
      accept [:numero, :client_nom, :description, :language, :date_emission, :statut]
    end

    update :update do
      accept [:numero, :client_nom, :description, :language, :date_emission, :statut]
    end

    destroy :destroy do
      require_atomic? false
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :org_id, :string, allow_nil?: false, public?: true
    attribute :numero, :string, allow_nil?: false, public?: true
    attribute :client_nom, :string, public?: true
    attribute :description, :string, public?: true
    attribute :date_emission, :date, public?: true

    attribute :statut, :atom,
      allow_nil?: false,
      public?: true,
      default: :brouillon,
      constraints: [one_of: [:brouillon, :envoyee, :payee]]

    attribute :language, :atom,
      allow_nil?: false,
      public?: true,
      default: :fr,
      constraints: [one_of: SearchCore.Language.supported_languages()]

    timestamps()
  end

  relationships do
    has_many :lignes, SearchDemo.Sales.Ligne do
      destination_attribute :facture_id
      public? true
    end
  end
end
