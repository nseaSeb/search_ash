defmodule SearchAsh do
  @moduledoc """
  An Ash extension that adds multilingual full-text search to a resource with one
  `search do … end` block.

      defmodule MyApp.Post do
        use Ash.Resource,
          domain: MyApp.Blog,
          data_layer: AshPostgres.DataLayer,
          extensions: [SearchAsh]

        search do
          fields [:title, :body]
          language_attribute :language
        end

        # ... attributes :title, :body, :language ...
      end

  From that block the extension generates, at compile time:

    * a `:search_text` string attribute (unless you defined one), holding the
      stemmed tokens;
    * a global change that keeps `:search_text` in sync on create/update, stemming
      each row in its own language via `SearchCore`;
    * a GIN expression index `to_tsvector('simple', search_text)` on the Postgres
      table — emitted into your migrations and tracked in the resource snapshot, so
      `mix ash_postgres.generate_migrations` round-trips it cleanly;
    * a `:search` read action taking `query` and `language` arguments, filtering on
      the tsvector with a tsquery built from the *same* pipeline (so a search for
      "chevaux" matches a row that stored "cheval").

  Stemming happens in Elixir, so the Postgres side always uses the `'simple'`
  configuration.
  """

  @search %Spark.Dsl.Section{
    name: :search,
    describe: "Configure multilingual full-text search for this resource.",
    examples: [
      """
      search do
        fields [:title, :body]
        language_attribute :language
      end
      """
    ],
    schema: [
      fields: [
        type: {:list, :atom},
        required: true,
        doc: "Attributes whose text is concatenated and indexed for search."
      ],
      weights: [
        type: {:map, :atom, {:in, [:a, :b, :c, :d]}},
        default: %{},
        doc:
          "How much each field counts towards the rank: `%{title: :a, body: :c}`. `:a` is " <>
            "the strongest, `:d` (the default for any field left out) the weakest — so a " <>
            "hit in a title outranks the same hit in a body."
      ],
      weight_values: [
        type: {:map, {:in, [:a, :b, :c, :d]}, :float},
        default: %{},
        doc:
          "What each weight class is worth when ranking, 0.0 to 1.0. Postgres' defaults " <>
            "are `%{a: 1.0, b: 0.4, c: 0.2, d: 0.1}`; override any of them, e.g. " <>
            "`%{b: 0.9}` to bring class `:b` almost level with `:a`. Note there are four " <>
            "classes and no more — a tsvector stores two bits of weight per lexeme — so " <>
            "fields are assigned to classes with `weights`, and the classes are priced here."
      ],
      language_attribute: [
        type: :atom,
        default: :language,
        doc: "Attribute holding each row's language (a `Stemmers` language atom)."
      ],
      search_text_attribute: [
        type: :atom,
        default: :search_text,
        doc: "Attribute the stemmed tokens are stored in (added automatically if absent)."
      ],
      index_name: [
        type: :string,
        required: false,
        doc: "Name of the generated GIN index. Defaults to `#{"\#{table}"}_search_idx`."
      ],
      action: [
        type: :atom,
        default: :search,
        doc: "Name of the generated read action."
      ],
      default_language: [
        type: :atom,
        default: :fr,
        doc:
          "Language used to stem the query when the `:search` action's `language` " <>
            "argument is omitted (e.g. from a generic list UI)."
      ],
      prefix?: [
        type: :boolean,
        default: true,
        doc:
          "Match the last-typed token as a prefix (search-as-you-type): a query " <>
            "\"boulan\" matches \"boulangerie\". Set false for exact stemmed matching."
      ],
      synonyms: [
        type: SearchAsh.Synonyms.type_spec(),
        required: false,
        doc:
          "Query-time expansion so a typed abbreviation also matches the words it stands " <>
            "for (`bl` finds `bon de livraison`). Either an inline map keyed by ISO base " <>
            "language (so `:en` also covers `:en_porter`) — " <>
            "`%{fr: %{\"bl\" => [\"bon de livraison\"]}}` — or a `{Module, :function}` " <>
            "returning that inner map for the base language, called on each search so a " <>
            "domain expert edits them without a deploy (keep it fast). Keys and values run " <>
            "through the same pipeline as the query, so a key matches however it was typed " <>
            "(`BL`/`bl`) and a multi-word value becomes an AND-group. Single-token keys " <>
            "only; one-way (add both entries for symmetry); off when unset. It widens the " <>
            "query, so more rows are scored (see `rank?`)."
      ],
      default_limit: [
        type: :pos_integer,
        required: false,
        doc:
          "Bound the results when the caller asks for no page at all. Setting it makes " <>
            "the action paginate by default, so it returns an `Ash.Page` rather than a " <>
            "list. Unset (the default) keeps today's behaviour — an unpaginated search " <>
            "reads every matching row."
      ],
      rank?: [
        type: :boolean,
        default: true,
        doc:
          "Rank results by `ts_rank` (most relevant first) and expose the score as the " <>
            "`:search_rank` calculation. Set false to only filter, leaving ordering to you."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@search],
    transformers: [
      SearchAsh.Transformers.AddSearchTextAttribute,
      SearchAsh.Transformers.AddSyncChange,
      SearchAsh.Transformers.AddSearchRank,
      SearchAsh.Transformers.AddSearchAction,
      SearchAsh.Transformers.AddSearchIndex
    ]

  require Ash.Query

  alias SearchAsh.Source.{Document, Index}

  @typedoc """
  What `reindex_one/3` did to the index row: rebuilt it (`:upserted`), deleted it
  (`:removed`), flagged it archived (`:archived`), or found nothing to do (`:noop`).
  """
  @type reindex_result :: :upserted | :removed | :archived | :noop

  @doc """
  Backfill the unified index for all existing rows of a `SearchAsh.Source` resource.

  Streams the source and upserts each row into its configured index. For a multitenant
  index, pass the tenant (call once per tenant):

      SearchAsh.reindex(MyApp.Sales.BonDeCommande, tenant: "org_42")

  Options are forwarded to the **source** read (`:tenant`, `:domain`, `:authorize?`, …), so
  you decide whose rows get backfilled; `:tenant` also scopes the index upsert, so mirrored
  rows land in the same tenant they came from.

  The upsert itself is not authorized: it mirrors rows the read already let through, and
  the index's policies are about what a user may *find*, not about whether the mirror may
  happen.

  This only ever **adds** rows to the index, so it cannot repair one whose source has gone
  away — and it reads the whole resource. To reconcile a single record after a write that
  bypassed Ash, use `reindex_one/3`; to drop index rows whose source is gone, `prune/2`.

  Returns `:ok`.
  """
  @spec reindex(module(), keyword()) :: :ok
  def reindex(source_resource, opts \\ []) do
    tenant = opts[:tenant]
    domain = opts[:domain]

    # Chunked so a `load`ed relationship (`extra_text`) costs one query per chunk of
    # records, not one per record — `Ash.stream!` already reads in batches anyway.
    source_resource
    |> Ash.stream!(opts)
    |> Stream.chunk_every(100)
    |> Stream.each(fn records ->
      source_resource
      |> Index.upsert_all(records, tenant, domain)
      |> Enum.each(fn {_result, notifications} -> Ash.Notifier.notify(notifications) end)
    end)
    |> Stream.run()
  end

  @doc """
  Reconcile **one** source record's index row, by re-reading the source.

  Use it after a write that bypassed Ash — a raw `Repo.query!`, a SQL cascade, a restore —
  which the sync and remove changes never saw:

      SearchAsh.reindex_one(MyApp.Sales.BonDeCommande, id, tenant: "org_42")

  It re-reads the record and reconciles, so the caller never has to work out whether the row
  should be added or removed:

    * the record is there → its document is rebuilt and upserted (`:upserted`);
    * it is gone → the resource's `on_destroy` decides — `:remove` deletes the index row
      (`:removed`), `:archive` keeps it flagged archived (`:archived`). Exactly what
      destroying it through Ash would have done;
    * it is gone and was never indexed → nothing to do (`:noop`).

  Idempotent: calling it twice does what calling it once does.

  Composite primary keys take a map or keyword list, as `Ash.get/3` does:

      SearchAsh.reindex_one(MyApp.Sales.Ligne, %{commande_id: id, numero: 2}, tenant: "org_42")

  ## Call it after the write commits, and outside any transaction

  It re-reads the source, so it must run **after** the bypassing write is committed and
  visible — otherwise it faithfully re-indexes the stale data it can still see. It also
  dispatches the index's notifications itself, which Ash can only do outside a transaction.
  Both point the same way: call it *after* your `Repo.transaction`, never inside it.

  ## Options

    * `:tenant` — for a multitenant source. Scopes both the read and the index write, so the
      row is reconciled in the tenant it belongs to. It cannot be inferred once the record is
      gone, so pass it whenever `reindex/2` would need it — and call once per tenant. A wrong
      tenant finds nothing and returns a cheerfully misleading `:noop`.
    * `:domain` — as for `Ash.get/3`.

  ## Why `:actor` and `authorize?: true` are rejected

  The source read always runs with `authorize?: false`. `reindex/2` forwards `:authorize?`
  safely because it only ever upserts — an authorized read that hides rows just backfills
  fewer of them. Here, absence is a **decision**: a row a policy hid is indistinguishable
  from one that was deleted (both read as `nil`), and would be reconciled by deleting its
  index row. Authorization answers "may this actor *see* it", which must not decide whether
  a row *exists*.

  `authorize?: false` turns off that filter and nothing else — the resource's `base_filter`
  and the tenant still apply, so an AshArchival-style soft delete is still correctly seen as
  gone.

  ## The primary read action must return every indexable row

  The record is read through the source's **primary read action** (there is deliberately no
  `:action` option), so that action decides what "exists" means here. `base_filter` is fine —
  a soft delete *should* read as gone. But a plain `filter` on the primary read is not
  authorization and is **not** turned off by `authorize?: false`: it always applies. A resource
  whose default read filters rows out (say `filter expr(published == true)`) will have live but
  filtered rows read as absent, and `reindex_one/3` will remove their index rows — even though
  the sync change indexed them (it fires on every write, regardless of read filters). Keep the
  primary read unfiltered beyond `base_filter`, or point `reindex_one/3`/`prune/2` at a resource
  whose default read returns everything.

  ## The archived branch keeps the indexed text

  For `on_destroy :archive`, the index row keeps its stored `search_text`/`label` and only
  flips `archived` — the source is gone, so there is nothing to rebuild from. If the text
  changed in the same breath as the deletion, the index retains the older one under
  `archived: true`. This is what the Ash destroy path does too.
  """
  @spec reindex_one(module(), term(), keyword()) :: reindex_result()
  def reindex_one(source_resource, id, opts \\ []) do
    validate_unauthorized_read_opts!(opts, "SearchAsh.reindex_one/3")
    tenant = opts[:tenant]

    # Derived up front, before the read: it is what the absent branch targets, and validating
    # the pk here means a malformed one is reported in `reindex_one/3`'s own terms rather than
    # surfacing as a generic "invalid primary key" from inside `Ash.get`.
    source_id = source_id_from_pk(source_resource, id)

    read_opts =
      opts
      |> Keyword.take([:tenant, :domain])
      |> Keyword.merge(authorize?: false, not_found_error?: false)

    {result, notifications} =
      case Ash.get(source_resource, id, read_opts) do
        {:ok, nil} ->
          Index.apply_destroy(source_resource, source_id, tenant)

        {:ok, record} ->
          upsert_read_record!(source_resource, record, tenant, opts[:domain])

        # Never let a read error fall into the "gone" branch: that would delete an index row
        # on the strength of a timeout.
        {:error, error} ->
          raise error
      end

    Ash.Notifier.notify(notifications)
    result
  end

  @doc """
  Remove index rows whose source record no longer exists — an orphan sweep.

  Where `reindex_one/3` reconciles one record you know changed, `prune/2` reconciles a whole
  source *in the deletion direction*: it reads which of the resource's rows are still live and
  drops every index row that no longer has one behind it. Use it to recover from writes that
  deleted source rows outside Ash and were never followed by a `reindex_one/3` — a bulk `DELETE`,
  a restore that went the wrong way, a botched migration:

      SearchAsh.prune(MyApp.Sales.BonDeCommande, tenant: "org_42")

  It streams the source (once) into the set of live `source_id`s, then, for each index row of
  this resource's `source_type` whose id is not in that set, applies the resource's
  `on_destroy` — `:remove` deletes it, `:archive` flags it archived, exactly as
  `reindex_one/3` would for a single gone record. Returns the number of index rows it acted on.

  It only ever *removes* (or archives); it never adds. Pair it with `reindex/2` for a full
  two-way reconcile — backfill missing rows, then sweep orphans.

  ## Call it outside any transaction

  Like `reindex_one/3`, it dispatches the index's notifications itself, so it must run outside
  a surrounding transaction. It reads and writes one index row per orphan, so it carries the
  same "built for small-to-medium tables, not a bulk-optimized job for very large datasets"
  caveat as `reindex/2`.

  ## Why `:actor` and `authorize?: true` are rejected

  For the same reason as `reindex_one/3`, and here the stakes are higher. `prune/2` decides an
  index row is an orphan by finding no live source behind it. If the live set were read with a
  policy applied, every row that policy *hides* would be missing from it and pruned — so
  running `prune/2` as a scoped user would delete the index rows of every record that user
  cannot see. The live set is always read with `authorize?: false`; absence must mean "does
  not exist", never "not visible to me".

  Like `reindex_one/3`, it decides existence from the source's **primary read action**, so
  that read must return every indexable row: a plain `filter` on it (not `base_filter`) makes
  filtered-but-live rows look like orphans and prune would delete them. See `reindex_one/3` for
  the full note.

  A multitenant source **must** feed a multitenant index — prune raises otherwise. A
  non-multitenant index cannot be tenant-scoped, so it would hand back every tenant's rows and
  prune would delete the ones belonging to other tenants.

  ## Options

    * `:tenant` — for a multitenant source. Scopes both the source stream and the index sweep,
      so prune only ever touches the tenant you name. Call once per tenant.
    * `:domain` — as for `Ash.stream!/2`.
    * `:stream_with`, `:allow_stream_with`, `:batch_size`, `:timeout` — forwarded to the source
      `Ash.stream!/2`. A read that can't keyset-stream needs `stream_with: :offset` (Ash streams
      with `:keyset` by default), the same option `reindex/2` needs for such a resource.

  It deliberately does **not** forward `:action`, `:filter` or anything else that would narrow
  which rows the stream yields — that would misclassify live rows as orphans and delete them.
  """
  @spec prune(module(), keyword()) :: non_neg_integer()
  def prune(source_resource, opts \\ []) do
    validate_unauthorized_read_opts!(opts, "SearchAsh.prune/2")
    refuse_unscopable_prune!(source_resource)
    tenant = opts[:tenant]

    # Forward the options that control *how* the source is streamed — never *which* rows it
    # yields. `prune/2` can't pass options through wholesale like `reindex/2` does: it forces
    # `authorize?: false`, and it must not let `:action`/`:filter` narrow the live set (that
    # would make live rows look like orphans and delete them). So it is an allowlist — safe
    # against a future option that changes visibility, at the cost of adding new stream knobs
    # here. `:stream_with`/`:allow_stream_with` matter for a read that can't keyset-stream.
    stream_opts =
      opts
      |> Keyword.take([:tenant, :domain, :stream_with, :allow_stream_with, :batch_size, :timeout])
      |> Keyword.put(:authorize?, false)

    live =
      source_resource
      |> Ash.stream!(stream_opts)
      |> Stream.map(&Document.source_id(source_resource, &1))
      |> MapSet.new()

    source_resource
    |> Index.prunable_source_ids(tenant)
    |> Enum.reject(&MapSet.member?(live, &1))
    |> Enum.reduce(0, fn source_id, acted ->
      {result, notifications} = Index.apply_destroy(source_resource, source_id, tenant)
      Ash.Notifier.notify(notifications)
      # A concurrent write could have removed the row between the read and now (`:noop`); only
      # count what this call actually changed.
      if result == :noop, do: acted, else: acted + 1
    end)
  end

  @doc """
  Count the `:global_search` matches of a `SearchAsh.GlobalIndex`, per `source_type` —
  the numbers a results page shows on its tabs:

      SearchAsh.counts_by_type(MyApp.Search.Document, "tomates", actor: user, tenant: org)
      #=> %{"facture" => 12, "produit" => 3}

  Runs the index's `:global_search` action, so everything composes as usual: the same
  matching (including `fuzzy?`), archived rows hidden, and the **index's policies
  applied** to the given `:actor` — a user only gets counts for what they may find.

  A blank `term` counts everything, per type — the numbers for a results page before
  the user types.

  ## Options

    * `:types` — the types to count (atoms or strings). `nil` or `[]` mean "not
      specified" (same convention as `:global_search`'s `types` argument): the types
      actually present in the matching rows are counted, found with one extra
      `distinct` read.
    * `:language`, `:include_archived?` — forwarded to `:global_search`'s arguments.
    * `:actor`, `:authorize?`, `:tenant`, `:domain` — as for any read.

  ## Cost

  One `Ash.count` **per type** (plus the `distinct` read when `:types` is omitted) —
  N small GIN-indexed counts, no hidden group-by. Fine for the handful of types a
  global index typically holds; pass `:types` to count only the tabs you display.
  """
  @spec counts_by_type(module(), String.t() | nil, keyword()) ::
          %{String.t() => non_neg_integer()}
  def counts_by_type(index, term, opts \\ []) do
    {arg_opts, query_opts} = Keyword.split(opts, [:types, :language, :include_archived?])

    args =
      arg_opts
      |> Keyword.take([:language, :include_archived?])
      |> Map.new()
      |> Map.put(:query, term)

    base =
      index
      |> Ash.Query.for_read(SearchAsh.GlobalIndex.Info.action(index), args, query_opts)
      # Counting needs no order and no rank — and a sort on a calculation would only
      # get in the aggregate's way. (`:load` also clears the loaded calculations.)
      |> Ash.Query.unset([:sort, :load])
      # And no page: an index with `default_limit` paginates by default, which would both
      # cap the distinct-type read and hand it an `Ash.Page` to enumerate.
      |> Ash.Query.page(false)

    arg_opts
    |> Keyword.get(:types)
    |> types_to_count(base)
    |> Map.new(fn type ->
      {type, base |> Ash.Query.filter(source_type == ^type) |> Ash.count!()}
    end)
  end

  # `[]` means "not specified", exactly as it does for `:global_search`'s `types`
  # argument — an empty tab multi-select must produce the full badge set, not `%{}`.
  defp types_to_count([_ | _] = types, _base), do: Enum.map(types, &to_string/1)
  defp types_to_count(_none, base), do: present_types(base)

  # The types that actually have matching rows, when the caller didn't name any.
  defp present_types(base) do
    base
    |> Ash.Query.distinct(:source_type)
    |> Ash.Query.select([:source_type])
    |> Ash.read!()
    |> Enum.map(& &1.source_type)
  end

  # `Index.upsert/3` answers `:noop` for a partially-loaded record, which is right on the
  # change path (a narrowed `select` on an update is real). Here the record comes from a full
  # `Ash.get`, so `:noop` can only mean a searchable field is `select_by_default? false` — in
  # which case the sync change cannot index this resource either. Say so, rather than
  # returning a `:noop` that reads as "reconciled, nothing to do" while the index stays stale.
  defp upsert_read_record!(resource, record, tenant, domain) do
    case Index.upsert(resource, record, tenant, domain) do
      {:noop, _notifications} -> raise ArgumentError, partial_record_message(resource)
      upserted -> upserted
    end
  end

  # `prune/2` scopes the source stream by tenant but relies on the index read honouring the
  # same tenant. If the source is multitenant and the index is not, the tenant is silently
  # ignored on the index side, so `prunable_source_ids/2` returns *every* tenant's rows — and
  # prune would delete other tenants' live index rows as "orphans". Refuse rather than destroy.
  # (`reindex_one/3` is keyed by a single near-unique `source_id`, not a set diff, so it is not
  # exposed the same way.) Such a config is already unsound — the index can't tenant-scope its
  # own search results — but only prune turns it destructive, so this is where we stop it.
  defp refuse_unscopable_prune!(source_resource) do
    index = SearchAsh.Source.Info.index(source_resource)

    if Ash.Resource.Info.multitenancy_strategy(source_resource) &&
         is_nil(Ash.Resource.Info.multitenancy_strategy(index)) do
      raise ArgumentError, unscopable_prune_message(source_resource, index)
    end
  end

  # Shared by `reindex_one/3` and `prune/2`: both decide what to do from whether a source row
  # is *there*, so both must read unauthorized (a policy-hidden live row must not read as gone).
  # `fun` only shapes the error message.
  defp validate_unauthorized_read_opts!(opts, fun) do
    cond do
      Keyword.has_key?(opts, :actor) ->
        raise ArgumentError, unauthorized_read_message(fun, ":actor")

      # `authorize?: false` is accepted: it is exactly what these functions do anyway.
      Keyword.get(opts, :authorize?, false) ->
        raise ArgumentError, unauthorized_read_message(fun, "authorize?: true")

      true ->
        :ok
    end
  end

  # Must agree byte-for-byte with `Document.source_id/2`, which derives the same string from a
  # record: the "gone" branch has no record and builds it from the caller's pk instead. If the
  # two ever disagreed, reconciliation would target no row and report a contented `:noop`.
  defp source_id_from_pk(resource, pk) do
    keys = Ash.Resource.Info.primary_key(resource)
    values = pk_values!(resource, keys, pk)

    keys
    |> Enum.map(&to_string(Map.fetch!(values, &1)))
    |> Enum.join(":")
  end

  # `Keyword.keyword?/1` is checked first: a keyword list is a list, not a map. `is_struct`
  # guards against a record being mistaken for a pk map.
  defp pk_values!(resource, keys, pk) do
    cond do
      Keyword.keyword?(pk) -> take_pk_keys!(resource, keys, Map.new(pk))
      is_map(pk) and not is_struct(pk) -> take_pk_keys!(resource, keys, pk)
      match?([_single], keys) -> %{hd(keys) => pk}
      true -> raise ArgumentError, scalar_for_composite_message(resource, keys, pk)
    end
  end

  defp take_pk_keys!(resource, keys, map) do
    Map.new(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> {key, value}
        :error -> raise ArgumentError, missing_pk_key_message(resource, keys, key)
      end
    end)
  end

  defp unauthorized_read_message(fun, option) do
    """
    #{fun} does not accept #{option}: its source read always runs with `authorize?: false`.

    It decides what to do from whether a source row is *there*. A row hidden by a policy reads \
    as absent, exactly like a deleted one — so an authorized read would have it delete the \
    index row of a live record. Whether an actor may see a row is a different question from \
    whether the row exists.

    `reindex/2` does forward `:authorize?`, because it only ever upserts: an authorized read \
    that hides rows simply backfills fewer of them.
    """
  end

  defp scalar_for_composite_message(resource, keys, pk) do
    """
    SearchAsh.reindex_one/3 got a scalar id (#{inspect(pk)}) for #{inspect(resource)}, whose \
    primary key has #{length(keys)} fields: #{inspect(keys)}.

    Pass every primary key field:

        SearchAsh.reindex_one(#{inspect(resource)}, #{example_pk(keys)}, tenant: …)
    """
  end

  defp missing_pk_key_message(resource, keys, missing) do
    """
    SearchAsh.reindex_one/3 was given a primary key for #{inspect(resource)} with no \
    #{inspect(missing)}. Its primary key is #{inspect(keys)}, and every field is needed to \
    identify the index row:

        SearchAsh.reindex_one(#{inspect(resource)}, #{example_pk(keys)}, tenant: …)
    """
  end

  defp unscopable_prune_message(source_resource, index) do
    """
    SearchAsh.prune/2 refuses to run: #{inspect(source_resource)} is multitenant but its \
    index #{inspect(index)} is not.

    prune diffs the index against the live source *for one tenant*, but a non-multitenant \
    index ignores the tenant — so it would return every tenant's rows and delete the ones \
    whose source lives in a different tenant. Give the index the same multitenancy as the \
    source (an `org_id`-style attribute strategy) so it can be scoped, then prune is safe.
    """
  end

  defp partial_record_message(resource) do
    """
    SearchAsh cannot reindex #{inspect(resource)}: the record was read in full, yet a field \
    the index needs is not loaded.

    This means one of its `fields` (or its language/`archived` attribute) is \
    `select_by_default? false`, so nothing can index this resource — the sync change skips it \
    on every write too. Make those attributes selected by default.
    """
  end

  defp example_pk(keys), do: "%{" <> Enum.map_join(keys, ", ", &"#{&1}: …") <> "}"
end
