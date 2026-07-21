defmodule SearchAsh.Source.Verifiers.VerifyFuzzyLabel do
  @moduledoc false
  # `fuzzy?` matches on `label_normalized`, which is derived from `label_field`. A source
  # feeding a fuzzy index without a `label_field` stores NULL there for every row, so the
  # trigram/substring branches never match anything of this resource — the user pays for
  # the pg_trgm extension and the trigram index and silently gets no typo tolerance.
  # A warning, not an error: the index may legitimately mix labelled and unlabelled
  # sources, with fuzziness only expected on the labelled ones.
  use Spark.Dsl.Verifier

  alias SearchAsh.Source.Info
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    index = Info.index(dsl_state)

    if is_nil(Info.label_field(dsl_state)) and fuzzy_index?(index) do
      module = Verifier.get_persisted(dsl_state, :module)

      {:warn,
       "SearchAsh: #{inspect(module)} feeds #{inspect(index)}, which has `fuzzy? true` — " <>
         "but declares no `label_field`. Fuzzy matching (trigram similarity and " <>
         "substring) runs on the normalized label, so this resource's rows will never " <>
         "fuzzy-match anything.\n\n" <>
         "Point `label_field` at the attribute users would type approximately (a name, " <>
         "a reference):\n\n" <>
         "    searchable do\n      label_field :name\n    end\n\n" <>
         "If this resource genuinely has nothing label-like, this warning is safe to " <>
         "ignore — full-text search on its `fields` is unaffected."}
    else
      :ok
    end
  end

  # The index is a compiled module by the time this source's verifier runs (the
  # `{:spark, SearchAsh.GlobalIndex}` DSL type already resolved it); the guard only
  # covers exotic compile orders, failing open rather than blocking compilation.
  defp fuzzy_index?(index) do
    Code.ensure_loaded?(index) && SearchAsh.GlobalIndex.Info.fuzzy?(index)
  end
end
