defmodule SearchAsh.Source.Document do
  @moduledoc false
  # Builds the index-document attributes for a source record. Shared by the sync change
  # and `SearchAsh.reindex/2`.
  alias SearchAsh.Source.Info

  def to_attrs(resource, record) do
    language = Map.get(record, Info.language_attribute(resource))

    text =
      resource
      |> Info.fields()
      |> Enum.map(&to_string(Map.get(record, &1) || ""))
      |> Enum.join(" ")

    %{
      source_type: Info.source_type(resource),
      source_id: source_id(resource, record),
      language: language,
      search_text: SearchCore.searchable_text(text, language),
      state: state(record, Info.state_attribute(resource)),
      label: label(record, Info.label_field(resource))
    }
  end

  def source_id(resource, record) do
    resource
    |> Ash.Resource.Info.primary_key()
    |> Enum.map(&to_string(Map.get(record, &1)))
    |> Enum.join(":")
  end

  defp state(_record, nil), do: :active
  defp state(record, attribute), do: Map.get(record, attribute) || :active

  defp label(_record, nil), do: nil
  defp label(record, field), do: to_string(Map.get(record, field) || "")
end
