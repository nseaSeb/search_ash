defmodule SearchAsh.Source.Document do
  @moduledoc false
  # Builds the index-document attributes for a source record. Shared by the sync change
  # and `SearchAsh.reindex/2`.
  alias SearchAsh.Source.Info

  def to_attrs(resource, record) do
    language = resolve_language!(resource, record)
    segments = segments(resource, record)
    label = label(record, Info.label_field(resource))

    %{
      source_type: Info.source_type(resource),
      source_id: source_id(resource, record),
      language: language,
      search_text: SearchCore.weighted(segments, language),
      archived: resolve_archived(record, Info.archived(resource)),
      label: label,
      label_normalized: normalize_label(label),
      excerpt: excerpt(segments, Info.excerpt_length(resource))
    }
    |> Map.merge(index_attributes(resource, record))
  end

  @doc """
  The `index_attribute` values for `record` — the extra index columns this resource
  fills, so they can be filtered and sorted on.

  Values are rewritten on every sync, which is what keeps them honest: they are derived
  from the record, so they cannot drift the way a mirrored authorization fact would.
  """
  def index_attributes(resource, record) do
    resource
    |> Info.index_attributes()
    |> Map.new(fn %{name: name, source: source} ->
      {name, resolve_index_attribute(record, source)}
    end)
  end

  defp resolve_index_attribute(record, fun) when is_function(fun, 1), do: fun.(record)
  defp resolve_index_attribute(record, attribute), do: Map.get(record, attribute)

  # The `{raw text, weight}` segments this record indexes: the configured fields carrying
  # their declared weight, then whatever each `extra_text` derives from the record
  # (typically from relations made available by `load`), carrying that entry's own class —
  # so a date you consider important can outweigh one you do not.
  #
  # Feeds both `search_text` (weighted, stemmed) and the optional `excerpt` (raw), so the
  # two can never describe different content.
  defp segments(resource, record) do
    weights = Info.weights(resource)

    fields =
      Enum.map(Info.fields(resource), fn field ->
        {to_string(Map.get(record, field) || ""), Map.get(weights, field, :d)}
      end)

    extra =
      Enum.flat_map(Info.extra_texts(resource), fn %{source: fun, weight: weight} ->
        record |> fun.() |> List.wrap() |> Enum.map(&{to_string(&1 || ""), weight})
      end)

    fields ++ extra
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
    (Info.fields(resource) ++
       language_attributes(resource) ++
       archived_attributes(resource) ++ index_attribute_attributes(resource))
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

  @doc false
  # The source attributes the attribute-driven `index_attribute`s read. Function-driven
  # ones are opaque, exactly like a function-driven `archived`, so they are not listed —
  # the function is responsible for only reading loaded attributes. Shared with the sync,
  # which watches these to know when a re-index is needed.
  def index_attribute_attributes(resource) do
    resource
    |> Info.index_attributes()
    |> Enum.map(& &1.source)
    |> Enum.filter(&is_atom/1)
  end

  defp resolve_archived(_record, nil), do: false
  defp resolve_archived(record, fun) when is_function(fun, 1), do: !!fun.(record)

  defp resolve_archived(record, attribute) when is_atom(attribute),
    do: Map.get(record, attribute) not in [nil, false]

  defp label(_record, nil), do: nil
  defp label(record, field), do: to_string(Map.get(record, field) || "")

  # The normalized label (`Maraîcher` → `maraicher`) that `:global_search` compares the
  # normalized query against, both for the exact/prefix/substring ranking tiers and for
  # the `fuzzy?` trigram match. `SearchCore.normalize/1` on BOTH sides — this column and
  # the query term in the GlobalSearch preparation — the same single-function symmetry
  # `SearchCore.searchable_text/tsquery` give the tsvector side. No stemming: this
  # answers "does the label read like the query", not "does it share stems".
  defp normalize_label(nil), do: nil
  defp normalize_label(label), do: SearchCore.normalize(label)

  # First `max` characters of the raw text, whitespace collapsed, cut on a word
  # boundary and `…`-suffixed when truncated. Stored as display data — the pipeline
  # never sees it.
  #
  # The raw text can be huge (`extra_text` over thousands of lines), so the collapse
  # streams graphemes and stops as soon as `max + 1` characters are gathered — the work
  # is bounded by the excerpt, not by the document.
  # Takes the segments rather than a joined string: with no `excerpt_length` there is
  # nothing to build, and joining a document that spans thousands of related records just
  # to throw it away is the kind of work that only shows up under load.
  defp excerpt(_segments, nil), do: nil

  defp excerpt(segments, max) do
    text =
      segments |> Enum.map(&elem(&1, 0)) |> Enum.intersperse(" ") |> collapsed_prefix(max + 1)

    if String.length(text) <= max do
      text
    else
      sliced = String.slice(text, 0, max)

      case sliced |> String.replace(~r/\S*$/u, "", global: false) |> String.trim_trailing() do
        # A single unbroken run longer than `max` (a reference, a URL): keep the hard cut.
        "" -> sliced <> "…"
        cut -> cut <> "…"
      end
    end
  end

  # Up to `limit` characters of `text` with whitespace runs collapsed to single spaces
  # and leading/trailing whitespace dropped (a pending space is only emitted once the
  # next word arrives, so a trailing run emits nothing).
  defp collapsed_prefix(parts, limit) do
    parts
    |> Stream.flat_map(&Stream.unfold(&1, fn t -> String.next_grapheme(t) end))
    |> Stream.transform(:leading, fn grapheme, state ->
      cond do
        String.match?(grapheme, ~r/\A\s\z/u) ->
          {[], if(state == :leading, do: state, else: :space)}

        state == :space ->
          {[" ", grapheme], :word}

        true ->
          {[grapheme], :word}
      end
    end)
    |> Enum.take(limit)
    |> IO.iodata_to_binary()
  end
end
