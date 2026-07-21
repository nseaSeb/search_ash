defmodule SearchAsh.Weights do
  @moduledoc false
  # Turns the `weight_values` map into the array `ts_rank` expects.
  #
  # Postgres stores two bits of weight per lexeme, so there are exactly four classes and
  # no more: fields are assigned to a class with `weights`, and each class is priced here.
  # `ts_rank` takes them in `{D, C, B, A}` order — ascending importance, which is the
  # reverse of how anyone talks about them.

  @defaults %{a: 1.0, b: 0.4, c: 0.2, d: 0.1}

  @doc "The `{D, C, B, A}` float list for `ts_rank`, with Postgres' defaults for anything unset."
  def to_array(overrides) when is_map(overrides) do
    values = Map.merge(@defaults, overrides)
    Enum.map([:d, :c, :b, :a], &Map.fetch!(values, &1))
  end
end
