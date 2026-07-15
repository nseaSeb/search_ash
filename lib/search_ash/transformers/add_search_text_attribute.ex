defmodule SearchAsh.Transformers.AddSearchTextAttribute do
  @moduledoc "Adds the `search_text` string attribute unless the resource already defines it."
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  @siblings [
    SearchAsh.Transformers.AddSearchTextAttribute,
    SearchAsh.Transformers.AddSyncChange,
    SearchAsh.Transformers.AddSearchAction,
    SearchAsh.Transformers.AddSearchIndex
  ]

  @impl true
  def transform(dsl) do
    name = Transformer.get_option(dsl, [:search], :search_text_attribute) || :search_text

    if attribute_defined?(dsl, name) do
      {:ok, dsl}
    else
      {:ok, attribute} =
        Ash.Resource.Builder.build_attribute(name, :string, allow_nil?: true, public?: false)

      {:ok, Transformer.add_entity(dsl, [:attributes], attribute)}
    end
  end

  defp attribute_defined?(dsl, name) do
    dsl
    |> Transformer.get_entities([:attributes])
    |> Enum.any?(&(&1.name == name))
  end

  # Run before Ash's core resource transformers (DefaultAccept, SetPrimaryActions,
  # type resolution, …) so the generated entities are seen, but not before our own
  # sibling transformers (avoids a cycle; siblings are independent).
  @impl true
  def before?(t), do: t not in @siblings
end
