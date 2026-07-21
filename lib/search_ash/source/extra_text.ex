defmodule SearchAsh.Source.ExtraText do
  @moduledoc """
  One derived text contribution to a record's searchable document — the target of an
  `extra_text` entry in a `searchable` block.

  `source` is a `record -> String.t() | [String.t()]` function; `weight` is the rank class
  its words carry, `:d` (the weakest, and Postgres' default) unless you say otherwise.
  """
  defstruct [:source, weight: :d, __spark_metadata__: nil]

  @type t :: %__MODULE__{source: (struct() -> term()), weight: :a | :b | :c | :d}
end
