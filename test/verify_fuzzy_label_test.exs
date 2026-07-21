defmodule SearchAsh.VerifyFuzzyLabelTest do
  @moduledoc """
  `fuzzy?` matches on the normalized label; a source feeding a fuzzy index without a
  `label_field` gets zero typo tolerance while still paying for pg_trgm and the
  trigram index. That misconfiguration should say so at compile time — as a warning,
  because a fuzzy index may legitimately mix labelled and unlabelled sources.
  """
  use ExUnit.Case, async: false
  import Spark.Test

  test "fuzzy index + no label_field — warns, but still compiles" do
    warning =
      assert_dsl_warning do
        defmodule Elixir.SearchAsh.VerifyFuzzyLabelTest.NoLabel do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            extensions: [SearchAsh.Source]

          searchable do
            index SearchAsh.Test.FuzzyDocument
            source_type :vfl
            fields [:title]
            language :fr
          end

          attributes do
            uuid_primary_key :id
            attribute :title, :string, public?: true
          end
        end
      end

    {message, _location} = warning
    assert message =~ "fuzzy? true"
    assert message =~ "no `label_field`"
    assert message =~ "label_field :name"

    # A warning, not an error: the module is usable.
    assert Code.ensure_loaded?(SearchAsh.VerifyFuzzyLabelTest.NoLabel)
  end

  test "fuzzy index + label_field — no warning" do
    refute_dsl_warnings do
      defmodule Elixir.SearchAsh.VerifyFuzzyLabelTest.WithLabel do
        use Ash.Resource,
          domain: nil,
          validate_domain_inclusion?: false,
          extensions: [SearchAsh.Source]

        searchable do
          index SearchAsh.Test.FuzzyDocument
          source_type :vfl
          fields [:title]
          language :fr
          label_field :title
        end

        attributes do
          uuid_primary_key :id
          attribute :title, :string, public?: true
        end
      end
    end
  end

  test "non-fuzzy index + no label_field — no warning" do
    refute_dsl_warnings do
      defmodule Elixir.SearchAsh.VerifyFuzzyLabelTest.NonFuzzyNoLabel do
        use Ash.Resource,
          domain: nil,
          validate_domain_inclusion?: false,
          extensions: [SearchAsh.Source]

        searchable do
          index SearchAsh.Test.SearchDocument
          source_type :vfl
          fields [:title]
          language :fr
        end

        attributes do
          uuid_primary_key :id
          attribute :title, :string, public?: true
        end
      end
    end
  end
end
