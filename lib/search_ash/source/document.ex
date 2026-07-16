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
      archived: resolve_archived(record, Info.archived(resource)),
      label: label(record, Info.label_field(resource))
    }
  end

  def source_id(resource, record) do
    resource
    |> Ash.Resource.Info.primary_key()
    |> Enum.map(&to_string(Map.get(record, &1)))
    |> Enum.join(":")
  end

  @doc """
  Whether every attribute the index needs is loaded on `record` (i.e. not `%Ash.NotLoaded{}`).
  The sync uses this to skip indexing when a searchable field, the language, or an
  attribute-driven `archived` isn't loaded, rather than index from incomplete data.

  A **function-driven** `archived` is opaque, so its inputs can't be checked here — the
  function is responsible for only reading loaded attributes (see the `archived` docs).
  """
  def loaded?(resource, record) do
    (Info.fields(resource) ++ [Info.language_attribute(resource) | archived_attributes(resource)])
    |> Enum.all?(&(not match?(%Ash.NotLoaded{}, Map.get(record, &1))))
  end

  defp archived_attributes(resource) do
    case Info.archived(resource) do
      attribute when is_atom(attribute) and not is_nil(attribute) -> [attribute]
      _fun_or_nil -> []
    end
  end

  defp resolve_archived(_record, nil), do: false
  defp resolve_archived(record, fun) when is_function(fun, 1), do: !!fun.(record)

  defp resolve_archived(record, attribute) when is_atom(attribute),
    do: Map.get(record, attribute) not in [nil, false]

  defp label(_record, nil), do: nil
  defp label(record, field), do: to_string(Map.get(record, field) || "")
end
