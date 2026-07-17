defmodule SearchAsh.Source.Verifiers.VerifyLanguage do
  @moduledoc false
  # Every indexed row is stemmed in some language, and the index stores it under
  # `allow_nil?: false`. A resource that resolves to no language only fails at write time,
  # inside the sync's after_action — which rolls back the whole source write. Catch that at
  # compile time instead: hard errors for what cannot possibly work, a warning for the
  # attribute that merely *might* be empty.
  use Spark.Dsl.Verifier

  alias SearchAsh.Source.Info
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)
    static = Info.language(dsl_state)
    attribute = Info.language_attribute(dsl_state)

    cond do
      static && Info.language_attribute_configured?(dsl_state) ->
        error(
          module,
          :language,
          "`language #{inspect(static)}` and `language_attribute #{inspect(attribute)}` " <>
            "are mutually exclusive: a resource either fixes one language for every row, " <>
            "or reads it per row from an attribute. Remove whichever you did not mean."
        )

      static && !SearchCore.Language.supported?(static) ->
        error(
          module,
          :language,
          "`language #{inspect(static)}` is not a supported language. Expected an ISO " <>
            "639-1 code such as `:fr` — see `SearchCore.Language.supported_languages/0` " <>
            "for the full list."
        )

      static ->
        :ok

      true ->
        verify_attribute(dsl_state, module, attribute)
    end
  end

  defp verify_attribute(dsl_state, module, attribute) do
    case Ash.Resource.Info.attribute(dsl_state, attribute) do
      nil ->
        error(
          module,
          :language_attribute,
          "this resource has no `#{inspect(attribute)}` attribute to read each row's " <>
            "language from, so indexing it would fail on every write.\n\n" <>
            "Either add the attribute, point `language_attribute` at an existing one, or — " <>
            "if every row is in the same language — fix it statically:\n\n" <>
            "    searchable do\n      language :fr\n    end"
        )

      # Nullable *and* no default: any row created without a language resolves to nil and
      # rolls its write back. A resource that always passes one explicitly still works, so
      # this warns rather than refusing to compile.
      %{allow_nil?: true, default: nil} ->
        {:warn,
         "SearchAsh: #{inspect(module)}'s #{inspect(attribute)} attribute is nullable and " <>
           "has no default, so any row written without a language cannot be indexed — and " <>
           "because the index sync runs inside the write's transaction, that rolls the " <>
           "whole write back.\n\n" <>
           "Give it `allow_nil?: false` or a `default:`, or — if every row of this " <>
           "resource is in the same language — fix it statically and drop the " <>
           "attribute:\n\n" <>
           "    searchable do\n      language :fr\n    end"}

      _attribute ->
        :ok
    end
  end

  defp error(module, option, message) do
    {:error, DslError.exception(module: module, path: [:searchable, option], message: message)}
  end
end
