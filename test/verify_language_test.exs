defmodule SearchAsh.VerifyLanguageTest do
  @moduledoc """
  The `searchable` block must resolve to a language at compile time. Otherwise the
  failure only surfaces on the first write, from inside the sync's after_action, as an
  opaque rollback of the source record.

  Spark converts verifier errors raised in its `@after_verify` hook into stderr output
  rather than propagating them, so these use `Spark.Test` to collect them as data —
  `assert_raise/2` would not see them.
  """
  use ExUnit.Case, async: false
  import Spark.Test

  describe "rejects a resource that cannot resolve a language" do
    test "no :language attribute and no static language" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:searchable, :language_attribute]} do
          defmodule Elixir.SearchAsh.VerifyLanguageTest.NoLanguageAtAll do
            use Ash.Resource,
              domain: nil,
              validate_domain_inclusion?: false,
              extensions: [SearchAsh.Source]

            searchable do
              index SearchAsh.Test.SearchDocument
              source_type :vlt
              fields [:title]
            end

            attributes do
              uuid_primary_key :id
              attribute :title, :string, public?: true
            end
          end
        end

      assert error.message =~ "no `:language` attribute"
      # The message must point at the way out, not just state the problem.
      assert error.message =~ "language :fr"
    end

    test "language_attribute pointing at an attribute that does not exist" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:searchable, :language_attribute]} do
          defmodule Elixir.SearchAsh.VerifyLanguageTest.MissingAttribute do
            use Ash.Resource,
              domain: nil,
              validate_domain_inclusion?: false,
              extensions: [SearchAsh.Source]

            searchable do
              index SearchAsh.Test.SearchDocument
              source_type :vlt
              fields [:title]
              language_attribute :locale
            end

            attributes do
              uuid_primary_key :id
              attribute :title, :string, public?: true
            end
          end
        end

      assert error.message =~ "no `:locale` attribute"
    end

    test "a static language that is not a supported language" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:searchable, :language]} do
          defmodule Elixir.SearchAsh.VerifyLanguageTest.BadLanguage do
            use Ash.Resource,
              domain: nil,
              validate_domain_inclusion?: false,
              extensions: [SearchAsh.Source]

            searchable do
              index SearchAsh.Test.SearchDocument
              source_type :vlt
              fields [:title]
              language :klingon
            end

            attributes do
              uuid_primary_key :id
              attribute :title, :string, public?: true
            end
          end
        end

      assert error.message =~ "not a supported language"
    end

    test "both language and language_attribute set" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:searchable, :language]} do
          defmodule Elixir.SearchAsh.VerifyLanguageTest.BothSet do
            use Ash.Resource,
              domain: nil,
              validate_domain_inclusion?: false,
              extensions: [SearchAsh.Source]

            searchable do
              index SearchAsh.Test.SearchDocument
              source_type :vlt
              fields [:title]
              language :french
              language_attribute :language
            end

            attributes do
              uuid_primary_key :id
              attribute :title, :string, public?: true
              attribute :language, :atom, public?: true
            end
          end
        end

      assert error.message =~ "mutually exclusive"
    end
  end

  describe "warns when the language attribute might be empty" do
    test "nullable with no default \u2014 warns, but still compiles" do
      warning =
        assert_dsl_warning do
          defmodule Elixir.SearchAsh.VerifyLanguageTest.NullableNoDefault do
            use Ash.Resource,
              domain: nil,
              validate_domain_inclusion?: false,
              extensions: [SearchAsh.Source]

            searchable do
              index SearchAsh.Test.SearchDocument
              source_type :vlt
              fields [:title]
            end

            attributes do
              uuid_primary_key :id
              attribute :title, :string, public?: true
              attribute :language, :atom, public?: true, allow_nil?: true
            end
          end
        end

      {message, _location} = warning
      assert message =~ "nullable and has no default"
      assert message =~ "rolls the whole write back"
      assert message =~ "language :fr"

      # A warning, not an error: the module is usable.
      assert Code.ensure_loaded?(SearchAsh.VerifyLanguageTest.NullableNoDefault)
    end

    test "nullable WITH a default \u2014 no warning" do
      refute_dsl_warnings do
        defmodule Elixir.SearchAsh.VerifyLanguageTest.NullableWithDefault do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            extensions: [SearchAsh.Source]

          searchable do
            index SearchAsh.Test.SearchDocument
            source_type :vlt
            fields [:title]
          end

          attributes do
            uuid_primary_key :id
            attribute :title, :string, public?: true
            attribute :language, :atom, public?: true, allow_nil?: true, default: :french
          end
        end
      end
    end

    test "non-nullable \u2014 no warning" do
      refute_dsl_warnings do
        defmodule Elixir.SearchAsh.VerifyLanguageTest.NonNullable do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            extensions: [SearchAsh.Source]

          searchable do
            index SearchAsh.Test.SearchDocument
            source_type :vlt
            fields [:title]
          end

          attributes do
            uuid_primary_key :id
            attribute :title, :string, public?: true
            attribute :language, :atom, public?: true, allow_nil?: false, default: :french
          end
        end
      end
    end
  end

  describe "accepts a resource that resolves a language" do
    test "a static language as an ISO code" do
      refute_dsl_errors do
        defmodule Elixir.SearchAsh.VerifyLanguageTest.IsoCode do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            extensions: [SearchAsh.Source]

          searchable do
            index SearchAsh.Test.SearchDocument
            source_type :vlt
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

    test "an algorithm variant" do
      refute_dsl_errors do
        defmodule Elixir.SearchAsh.VerifyLanguageTest.Variant do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            extensions: [SearchAsh.Source]

          searchable do
            index SearchAsh.Test.SearchDocument
            source_type :vlt
            fields [:title]
            language :en_porter
          end

          attributes do
            uuid_primary_key :id
            attribute :title, :string, public?: true
          end
        end
      end
    end

    test "an existing :language attribute with no static language" do
      refute_dsl_errors do
        defmodule Elixir.SearchAsh.VerifyLanguageTest.AttributeOnly do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            extensions: [SearchAsh.Source]

          searchable do
            index SearchAsh.Test.SearchDocument
            source_type :vlt
            fields [:title]
          end

          attributes do
            uuid_primary_key :id
            attribute :title, :string, public?: true
            attribute :language, :atom, public?: true
          end
        end
      end
    end
  end
end
