defmodule PairingsEngine.Norms.CountsBreakdownTest do
  # async: true — pure, no database.
  use ExUnit.Case, async: true

  alias PairingsEngine.Norms.CountsBreakdown
  alias PairingsEngine.Tournaments.Player

  defp player(overrides) do
    struct(%Player{name: "Player, Test", federation: "BEL", fide_rating: 0, title: ""}, overrides)
  end

  test "categories/0 lists every report category in report order" do
    keys = CountsBreakdown.categories() |> Enum.map(&elem(&1, 0))
    assert keys == [:rated, :unrated, :gm, :im, :fm, :wgm, :wim, :wfm]
  end

  test "splits rated vs unrated by fide_rating, keeping the actual players" do
    rated = player(%{name: "Rated, One", fide_rating: 1900})
    unrated = player(%{name: "Unrated, One", fide_rating: 0})

    breakdown = CountsBreakdown.breakdown([rated, unrated], "BEL")

    assert breakdown.rated.total == 1
    assert breakdown.rated.players == [rated]
    assert breakdown.unrated.total == 1
    assert breakdown.unrated.players == [unrated]
  end

  test "CM/WCM are not counted under any title category (federation grades, not FIDE titles)" do
    cm = player(%{name: "Grade, CM", title: "CM"})
    breakdown = CountsBreakdown.breakdown([cm], "BEL")

    assert Enum.all?(breakdown, fn {key, cat} ->
             key in [:rated, :unrated] or cat.total == 0
           end)
  end

  test "feds counts distinct non-blank federations, host counts the host federation only" do
    players = [
      player(%{title: "GM", federation: "BEL"}),
      player(%{title: "GM", federation: "BEL"}),
      player(%{title: "GM", federation: "NED"}),
      player(%{title: "GM", federation: ""})
    ]

    gm = CountsBreakdown.breakdown(players, "BEL").gm

    assert gm.total == 4
    assert gm.feds == 2
    assert gm.host == 2
  end

  test "a nil/blank host_federation counts zero hosts, never matching a blank player federation" do
    players = [player(%{title: "IM", federation: ""})]

    assert CountsBreakdown.breakdown(players, nil).im.host == 0
    assert CountsBreakdown.breakdown(players, "").im.host == 0
  end
end
