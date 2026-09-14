defmodule PairingsEngine.Federations.BEL.ClubsTest do
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.Federations.BEL.Clubs

  test "with nothing stored and no sources, resolve/2 returns an empty map" do
    assert Clubs.resolve(nil, nil) == %{}
  end

  test "a zip club wins over a url club for the same number" do
    result = Clubs.resolve(%{42 => "From Zip"}, %{42 => "From URL"})
    assert result[42] == "From Zip"
  end

  test "a url club is kept when the zip has nothing for that number" do
    result = Clubs.resolve(%{1 => "Zip Club"}, %{2 => "URL Club"})
    assert result[1] == "Zip Club"
    assert result[2] == "URL Club"
  end

  test "a name learned once survives a later sync where neither source mentions it" do
    Clubs.resolve(%{42 => "KGSRL"}, nil)

    # Next month's zip has no clubs table, and no URL is configured either.
    result = Clubs.resolve(nil, nil)

    assert result[42] == "KGSRL"
  end

  test "a fresher name for the same number overwrites the stored one" do
    Clubs.resolve(%{42 => "Old Name"}, nil)
    result = Clubs.resolve(%{42 => "New Name"}, nil)

    assert result[42] == "New Name"
    assert Clubs.name_for(42) == "New Name"
  end

  test "name_for/1 is nil for an unknown club, and nil for nil" do
    assert Clubs.name_for(999) == nil
    assert Clubs.name_for(nil) == nil
  end

  test "malformed entries (non-integer key, blank name) are ignored" do
    result = Clubs.resolve(%{"not_an_int" => "x", 5 => ""}, nil)
    refute Map.has_key?(result, "not_an_int")
    refute Map.has_key?(result, 5)
  end
end
