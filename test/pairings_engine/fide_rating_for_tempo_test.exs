defmodule PairingsEngine.FideRatingForTempoTest do
  @moduledoc """
  `PairingsEngine.Fide.rating_for_tempo/2` — pure, no DB — is what picks
  which of a `FidePlayer`'s three FIDE ratings (Standard/Rapid/Blitz) a
  tournament actually uses, per the tournament's own `standard` cadence
  classification (`PairingsEngine.RateOfPlay`).
  """
  use ExUnit.Case, async: true

  alias PairingsEngine.Fide
  alias PairingsEngine.Fide.FidePlayer

  defp player(attrs) do
    struct(
      %FidePlayer{fide_id: 1, name: "Test, Player"},
      attrs
    )
  end

  test "nil fide_player always returns nil, regardless of standard" do
    assert Fide.rating_for_tempo(nil, "standard") == nil
    assert Fide.rating_for_tempo(nil, "rapid") == nil
    assert Fide.rating_for_tempo(nil, "blitz") == nil
    assert Fide.rating_for_tempo(nil, nil) == nil
  end

  test "\"standard\" reads standard_rating, ignoring rapid/blitz entirely" do
    fp = player(standard_rating: 2000, rapid_rating: 1900, blitz_rating: 1800)
    assert Fide.rating_for_tempo(fp, "standard") == 2000
  end

  test "blank/nil/unrecognised standard falls back to the Standard list, matching RateOfPlay.list_for/1" do
    fp = player(standard_rating: 2000, rapid_rating: 1900, blitz_rating: 1800)
    assert Fide.rating_for_tempo(fp, nil) == 2000
    assert Fide.rating_for_tempo(fp, "") == 2000
    assert Fide.rating_for_tempo(fp, "classical") == 2000
  end

  test "\"rapid\" reads rapid_rating when the player has one" do
    fp = player(standard_rating: 2000, rapid_rating: 1900, blitz_rating: 1800)
    assert Fide.rating_for_tempo(fp, "rapid") == 1900
  end

  test "\"blitz\" reads blitz_rating when the player has one" do
    fp = player(standard_rating: 2000, rapid_rating: 1900, blitz_rating: 1800)
    assert Fide.rating_for_tempo(fp, "blitz") == 1800
  end

  test "\"rapid\" falls back to standard_rating when the player has no rapid rating yet" do
    fp = player(standard_rating: 2000, rapid_rating: nil, blitz_rating: 1800)
    assert Fide.rating_for_tempo(fp, "rapid") == 2000
  end

  test "\"blitz\" falls back to standard_rating when the player has no blitz rating yet" do
    fp = player(standard_rating: 2000, rapid_rating: 1900, blitz_rating: nil)
    assert Fide.rating_for_tempo(fp, "blitz") == 2000
  end

  test "a player with no rating in any list returns nil, not 0" do
    fp = player(standard_rating: nil, rapid_rating: nil, blitz_rating: nil)
    assert Fide.rating_for_tempo(fp, "standard") == nil
    assert Fide.rating_for_tempo(fp, "rapid") == nil
    assert Fide.rating_for_tempo(fp, "blitz") == nil
  end
end
