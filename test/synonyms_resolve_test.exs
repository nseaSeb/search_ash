defmodule SearchAsh.SynonymsResolveTest do
  @moduledoc """
  Unit tests for `SearchAsh.Synonyms.resolve/2`, the shared resolution both extensions'
  `Info.synonyms/2` delegate to. Pure — no resource or database needed.
  """
  use ExUnit.Case, async: true

  alias SearchAsh.Synonyms

  defmodule Callback do
    @moduledoc false
    def for_lang(:en), do: %{"color" => ["colour"]}
    def for_lang(:fr), do: %{"bl" => ["bon de livraison"]}
    def for_lang(_other), do: %{}
    def not_a_map(_language), do: :oops
  end

  test "an inline map is keyed by ISO base language, so :en also covers :en_porter" do
    map = %{en: %{"color" => ["colour"]}}
    # The regression this guards: before base-keying, `:en_porter` (a distinct supported
    # atom) missed a `%{en: …}` map and synonyms silently did nothing.
    assert Synonyms.resolve(map, :en) == %{"color" => ["colour"]}
    assert Synonyms.resolve(map, :en_porter) == %{"color" => ["colour"]}
  end

  test "the {module, function} callback also receives the base language" do
    assert Synonyms.resolve({Callback, :for_lang}, :fr) == %{"bl" => ["bon de livraison"]}
    assert Synonyms.resolve({Callback, :for_lang}, :en_porter) == %{"color" => ["colour"]}
  end

  test "a callback returning anything but a map degrades to %{}, not junk" do
    assert Synonyms.resolve({Callback, :not_a_map}, :fr) == %{}
  end

  test "nil (unset) and a language with no entry both yield %{}" do
    assert Synonyms.resolve(nil, :fr) == %{}
    assert Synonyms.resolve(%{fr: %{"bl" => ["bon de livraison"]}}, :de) == %{}
  end
end
