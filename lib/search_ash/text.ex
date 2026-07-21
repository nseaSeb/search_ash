defmodule SearchAsh.Text do
  @moduledoc false
  # How an attribute value becomes indexable text.
  #
  # `to_string/1` is the obvious choice and the wrong one for a list. It takes the
  # iodata path, so a `{:array, :string}` attribute — a tag list, the common case —
  # silently concatenates: `["urgent", "vip"]` becomes `"urgentvip"`. Neither tag is
  # findable afterwards, AND a junk token enters the index, with nothing to signal it.
  # `["bl-2024", "urgent"]` is worse still: `"bl-2024urgent"` tokenizes to
  # `["bl", "2024urgent"]`. On a list of *atoms* it raises instead, which at least shows.
  #
  # So members are joined with a separator and the pipeline tokenizes them apart. Joining
  # with `Enum.join/1` — no separator — would reproduce the exact corruption this exists
  # to fix.

  @doc "Turn an attribute value into text the pipeline can tokenize."
  @spec indexable(term()) :: String.t()
  def indexable(nil), do: ""

  # `false` indexed as nothing before this module existed, because the call sites wrote
  # `to_string(value || "")` and `false` fell through the `||`. That was an accident of
  # the nil guard rather than a decision, but a patch release should change only what it
  # set out to change — so it is kept, and named here so nobody "tidies" it away.
  # (`true` has always indexed as "true". The asymmetry is inherited, not chosen.)
  def indexable(false), do: ""

  def indexable(value) when is_list(value), do: Enum.map_join(value, " ", &indexable/1)

  # A map has no obvious text form — keys, values, or both? Guessing would put arbitrary
  # tokens in the index. Without this clause the failure is a bare `Protocol.UndefinedError`
  # raised from inside the library, *inside the source write's transaction*, which rolls the
  # caller's write back with nothing pointing at the cause.
  def indexable(value) when is_map(value) and not is_struct(value) do
    raise ArgumentError, """
    SearchAsh cannot index a map as searchable text: #{inspect(value, limit: 3)}

    A map has no single text form, so `fields` will not guess one. Derive the text you
    actually want to search instead:

        extra_text fn record -> Map.values(record.metadata) end

    (Structs that implement String.Chars — Date, Decimal, and so on — are fine in `fields`.)
    """
  end

  def indexable(value), do: to_string(value)
end
