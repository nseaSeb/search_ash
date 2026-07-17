defmodule SearchAsh.Source.Document do
  @moduledoc false
  # Builds the index-document attributes for a source record. Shared by the sync change
  # and `SearchAsh.reindex/2`.
  alias SearchAsh.Source.Info

  def to_attrs(resource, record) do
    language = resolve_language!(resource, record)

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
    (Info.fields(resource) ++ language_attributes(resource) ++ archived_attributes(resource))
    |> Enum.all?(&(not match?(%Ash.NotLoaded{}, Map.get(record, &1))))
  end

  @doc """
  The language to stem this record in: the resource's static `language` when set,
  otherwise the value of its `language_attribute`.

  `nil` when the record resolves to no language, or to one the installed stemmer does not
  support — `to_attrs/2` turns that into a message naming the resource.
  """
  def resolve_language(resource, record) do
    lang = raw_language(resource, record)
    if SearchCore.Language.supported?(lang), do: lang
  end

  defp raw_language(resource, record) do
    case Info.language(resource) do
      nil -> Map.get(record, Info.language_attribute(resource))
      static -> static
    end
  end

  # The index stores `language` under `allow_nil?: false`, and the sync runs inside the
  # source write's transaction — so an unresolvable language rolls the write back. Say why
  # here, rather than letting a bare ArgumentError surface from inside the stemmer.
  defp resolve_language!(resource, record) do
    resolve_language(resource, record) ||
      raise ArgumentError, no_language_message(resource, record)
  end

  @doc false
  # Public only so the two branches can be unit-tested: the static one is otherwise only
  # reachable when the installed stemmer drops a language the verifier accepted.
  def no_language_message(resource, record) do
    case Info.language(resource) do
      nil -> attribute_message(resource, record)
      static -> static_message(resource, static)
    end
  end

  # This resource fixes one language for every row, so it has no language attribute to
  # talk about — only the `language` option itself can be at fault. Advising the attribute
  # here would send the reader after a column that does not exist, and telling them to
  # write `language :fr` would be telling them to do what already failed.
  defp static_message(resource, static) do
    """
    SearchAsh cannot index #{inspect(resource)}: its `language #{inspect(static)}` is not \
    a supported language.

    This resource fixes one language for every row, so there is no language attribute to \
    change — the `language` option in its `searchable` block is what needs a supported \
    value:

        searchable do
          language :fr
        end

    Accepted languages: `SearchCore.Language.supported_languages/0`.
    """
  end

  defp attribute_message(resource, record) do
    attribute = Info.language_attribute(resource)
    value = Map.get(record, attribute)

    detail =
      if is_nil(value) do
        "its #{inspect(attribute)} attribute is nil"
      else
        "#{inspect(value)} (from #{inspect(attribute)}) is not a supported language"
      end

    """
    SearchAsh cannot index #{inspect(resource)}: #{detail}.

    Every indexed row needs a language. Either guarantee #{inspect(attribute)} always has \
    a supported one (`allow_nil?: false`, or a `default:`), or — if every row of this \
    resource is in the same language — fix it statically and drop the attribute:

        searchable do
          language :fr
        end

    Accepted languages: `SearchCore.Language.supported_languages/0`.
    """
  end

  # A static language needs no attribute on the record, so there is nothing to wait for.
  defp language_attributes(resource) do
    if Info.language(resource), do: [], else: [Info.language_attribute(resource)]
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
