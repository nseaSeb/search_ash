defmodule SearchAsh.Test.Order do
  @moduledoc false
  # `load` + `extra_text` + `excerpt_length`: the searchable text of an order includes
  # the descriptions of its lines, and an excerpt is stored for display.
  use Ash.Resource,
    domain: SearchAsh.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [SearchAsh.Source]

  postgres do
    table "test_orders"
    repo SearchAsh.Test.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? true
  end

  searchable do
    index SearchAsh.Test.SearchDocument
    source_type :order
    fields [:number]
    language_attribute :language
    label_field :number
    load [:lines]
    # Two derived contributions with different classes: the lines are body text, the
    # date spelled out matters more (this is the created_date vs updated_date case).
    extra_text fn order -> Enum.map(order.lines, & &1.description) end
    extra_text(&SearchAsh.Test.Order.date_words/1, weight: :b)
    excerpt_length 40

    # Typed columns: an attribute name (watched by the sync) and a computed value.
    index_attribute :document_date, :date_emission
    index_attribute :client_ref, :client_ref
    index_attribute :line_count, &length(&1.lines)
  end

  actions do
    defaults [:read]

    create :create do
      accept [:number, :language, :date_emission, :client_ref]
    end

    update :update do
      accept [:number, :language, :date_emission, :client_ref]
    end

    destroy :destroy do
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :org_id, :string, allow_nil?: false, public?: true
    attribute :number, :string, public?: true
    attribute :date_emission, :date, public?: true
    attribute :client_ref, :string, public?: true

    attribute :language, :atom,
      allow_nil?: false,
      public?: true,
      default: :fr,
      constraints: [one_of: SearchCore.Language.supported_languages()]
  end

  @doc false
  # The date written out, so a search box query like "juillet" finds the order.
  @months ~w(janvier fevrier mars avril mai juin juillet aout septembre octobre novembre decembre)
  def date_words(%{date_emission: %Date{} = d}),
    do: "#{d.day} #{Enum.at(@months, d.month - 1)} #{d.year}"

  def date_words(_), do: ""

  relationships do
    has_many :lines, SearchAsh.Test.OrderLine do
      destination_attribute :order_id
      public? true
    end
  end
end
