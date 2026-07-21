defmodule SearchAsh.Source.IndexAttribute do
  @moduledoc """
  One extra index column filled from a source record — the target of an
  `index_attribute` entry in a `searchable` block.

  `source` is either an **attribute name** (the value is read from the record, and the
  sync watches that attribute so a change to it alone still re-indexes) or a
  **`record -> value` function** (opaque, so the document is rebuilt on every write).
  """
  # `__spark_metadata__` is required of any Spark entity target (source annotations).
  defstruct [:name, :source, :__spark_metadata__]

  @type t :: %__MODULE__{name: atom(), source: atom() | (struct() -> term())}
end
