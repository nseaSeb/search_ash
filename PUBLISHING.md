# Publishing `search_ash` to Hex

`search_ash` depends on `search_core`, so **publish `search_core` first**
(see `search_core/PUBLISHING.md`). A path dependency cannot be published.

Once `search_core` is on Hex:

```sh
# 1. switch the dependency from path to Hex in mix.exs
#      {:search_core, path: "../search_core"}  ->  {:search_core, "~> 0.1"}

# 2. public repo + push (the examples/ dir stays in the repo but not in the package —
#    the mix.exs `files` list ships only lib/, docs, LICENSE, CHANGELOG)
gh repo create nseaSeb/search_ash --public --source=. --remote=origin --push

# 3. sanity checks
mix hex.build      # now succeeds (no path deps); review the file list
mix docs           # no warnings

# 4. publish
mix hex.publish
```

`mix test` needs a reachable Postgres (it creates `search_ash_test` and a small schema).
CI is optional and none is required to publish.
