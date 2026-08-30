defmodule PairingsEngine.TiebreakWorkingTest do
  @moduledoc """
  The premise of publishing the working is that it ADDS UP to the number
  beside it. A public page showing five contributions under a total they do
  not reach is worse than showing no working at all - it reads as a bug in
  the arbiter's software, in front of the players.

  So the central test here is not "are the parts plausible" but "does every
  part list total exactly what `Standings` published", across tournaments
  shaped to hit the awkward cases: byes, forfeits, an unrated player, a
  withdrawal, an odd field.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Standings, TiebreakWorking}
  alias PairingsEngine.Tournaments.{Pairing, Player, Round, Tournament}

  # ARO/AROC1 are the one pair whose total is not the column: the parts are
  # opponents' ratings and the column is their average.
  @summed ~w(BH BHC1 BHC2 MBH SB KS PS WIN WON BPG)

  describe "the working totals what the standings published" do
    for {name, builder} <- [
          {"a clean four-player event", :clean},
          {"an odd field, so somebody gets a pairing-allocated bye", :odd},
          {"forfeits and a played 0-0", :forfeits},
          {"a requested bye and an absence", :byes},
          {"a player who withdrew mid-event", :withdrawal}
        ] do
      test "#{name}" do
        tournament = apply(__MODULE__, unquote(builder), [])
        entries = Standings.standings(tournament)
        working = TiebreakWorking.working(entries, tournament, tournament.tiebreaks)

        for entry <- entries, code <- tournament.tiebreaks, code in @summed do
          parts = get_in(working, [entry.player.id, code])

          assert parts, "#{code} has no working for #{entry.player.name}"

          assert parts.total == entry.tiebreaks[code],
                 "#{code} for #{entry.player.name}: working totals #{parts.total}, " <>
                   "standings published #{entry.tiebreaks[code]}\n" <>
                   inspect(parts.parts, pretty: true)
        end
      end
    end
  end

  describe "the parts say what kind they are" do
    test "an unplayed round contributes a virtual opponent, named as such" do
      tournament = byes()
      entries = Standings.standings(tournament)
      working = TiebreakWorking.working(entries, tournament, ["BH"])

      # The player with the requested bye has a round with no opponent to
      # name; Article 16.4's capped dummy is what fills it.
      virtual =
        working
        |> Map.values()
        |> Enum.flat_map(& &1["BH"].parts)
        |> Enum.filter(&(&1.kind == :virtual))

      assert virtual != []
      assert Enum.all?(virtual, &is_nil(&1.opponent_id))
    end

    test "a cut modifier marks the round it discarded instead of hiding it" do
      tournament = clean()
      entries = Standings.standings(tournament)
      working = TiebreakWorking.working(entries, tournament, ["BH", "BHC1"])

      for entry <- entries do
        bh = working[entry.player.id]["BH"]
        c1 = working[entry.player.id]["BHC1"]

        # Same rounds either way - Cut-1 discards a contribution, it does not
        # shorten the list.
        assert length(bh.parts) == length(c1.parts)
        assert Enum.count(c1.parts, &(&1.kind == :cut)) == 1

        cut = Enum.find(c1.parts, &(&1.kind == :cut))
        assert c1.total == Float.round(bh.total - cut.value, 2)
      end
    end

    test "Koya shows the opponents it did not count, at zero" do
      tournament = clean()
      entries = Standings.standings(tournament)
      working = TiebreakWorking.working(entries, tournament, ["KS"])

      # The bottom player faced opponents above 50% and scored nothing off
      # them; somebody in this field has an excluded part either way.
      all = working |> Map.values() |> Enum.flat_map(& &1["KS"].parts)

      assert Enum.any?(all, &(&1.kind == :excluded))
      assert Enum.all?(all, &(&1.kind != :excluded or &1.value == 0.0))
    end

    test "every part names the round it came from, so a card can join on it" do
      tournament = forfeits()
      entries = Standings.standings(tournament)
      working = TiebreakWorking.working(entries, tournament, tournament.tiebreaks)

      for {_id, codes} <- working, {_code, %{parts: parts}} <- codes, part <- parts do
        assert is_integer(part.round)
        assert part.kind in [:played, :virtual, :cut, :excluded]
      end
    end
  end

  describe "what has no working" do
    test "Direct Encounter is absent rather than invented" do
      tournament = clean()
      entries = Standings.standings(tournament)
      working = TiebreakWorking.working(entries, tournament, ["DE", "BH"])

      for entry <- entries do
        refute Map.has_key?(working[entry.player.id], "DE")
        assert Map.has_key?(working[entry.player.id], "BH")
      end
    end

    test "an unknown code is absent rather than a crash" do
      tournament = clean()
      entries = Standings.standings(tournament)

      assert %{} = working = TiebreakWorking.working(entries, tournament, ["NOPE"])
      assert Enum.all?(Map.values(working), &(&1 == %{}))
    end
  end

  describe "ARO, whose total is a sum where the column is an average" do
    test "the counted parts average to the published number" do
      tournament = clean()
      entries = Standings.standings(tournament)
      working = TiebreakWorking.working(entries, tournament, ["ARO"])

      for entry <- entries do
        parts = working[entry.player.id]["ARO"].parts
        counted = Enum.filter(parts, &(&1.kind == :played))

        expected =
          if counted == [],
            do: 0.0,
            else: Float.round(Enum.sum(Enum.map(counted, & &1.value)) / length(counted))

        assert expected == entry.tiebreaks["ARO"]
      end
    end
  end

  ## ---------- fixtures ----------
  ##
  ## Public because the generated tests above call them by name through
  ## `apply/3`.

  @codes ~w(BH BHC1 BHC2 MBH SB KS PS WIN WON BPG ARO)

  def clean do
    t = tournament("Clean", 3)
    [a, b, c, d] = players(t, [{"A", 2000}, {"B", 1900}, {"C", 1800}, {"D", 1700}])

    rounds(t, [
      {1, [{a, d, "1-0"}, {b, c, "1/2-1/2"}]},
      {2, [{a, b, "1-0"}, {c, d, "1-0"}]},
      {3, [{a, c, "1/2-1/2"}, {b, d, "1-0"}]}
    ])

    reload(t)
  end

  def odd do
    t = tournament("Odd", 2)
    [a, b, c] = players(t, [{"A", 2000}, {"B", 1900}, {"C", 1800}])

    rounds(t, [
      {1, [{a, b, "1-0"}, {c, nil, "bye"}]},
      {2, [{a, c, "1/2-1/2"}, {b, nil, "bye"}]}
    ])

    reload(t)
  end

  def forfeits do
    t = tournament("Forfeits", 3)
    [a, b, c, d] = players(t, [{"A", 2000}, {"B", 1900}, {"C", 1800}, {"D", 0}])

    rounds(t, [
      {1, [{a, d, "1-0FF"}, {b, c, "0-1"}]},
      {2, [{a, b, "0-0"}, {c, d, "0-0FF"}]},
      {3, [{a, c, "1-0U"}, {b, d, "0-1"}]}
    ])

    reload(t)
  end

  def byes do
    t = tournament("Byes", 3)
    [a, b, c, d] = players(t, [{"A", 2000}, {"B", 1900}, {"C", 1800}, {"D", 1700}])

    rounds(t, [
      {1, [{a, b, "1-0"}, {c, d, "1/2-1/2"}]},
      {2, [{a, c, "1-0"}]},
      {3, [{a, d, "1/2-1/2"}, {b, c, "1-0"}]}
    ])

    Repo.insert_all("byes", [
      %{tournament_id: t.id, player_id: b.id, round: 2, type: "requested-half"},
      %{tournament_id: t.id, player_id: d.id, round: 2, type: "absent"}
    ])

    reload(t)
  end

  def withdrawal do
    t = tournament("Withdrawal", 3)
    [a, b, c, d] = players(t, [{"A", 2000}, {"B", 1900}, {"C", 1800}, {"D", 1700}])

    rounds(t, [
      {1, [{a, d, "1-0"}, {b, c, "1-0"}]},
      {2, [{a, b, "1/2-1/2"}, {c, d, "1-0"}]},
      # D withdrew: no board in round 3, and no bye row either.
      {3, [{a, c, "1-0"}]}
    ])

    reload(t)
  end

  defp tournament(name, rounds_count) do
    Repo.insert!(%Tournament{
      name: name,
      type: "swiss",
      rounds_count: rounds_count,
      points_win: 1.0,
      points_draw: 0.5,
      points_loss: 0.0,
      tiebreaks: @codes
    })
  end

  defp players(t, specs) do
    for {{name, rating}, nr} <- Enum.with_index(specs, 1) do
      Repo.insert!(%Player{
        tournament_id: t.id,
        name: name,
        pairing_number: nr,
        fide_rating: rating
      })
    end
  end

  defp rounds(t, schedule) do
    for {number, boards} <- schedule do
      round = Repo.insert!(%Round{tournament_id: t.id, number: number, status: "finished"})

      boards
      |> Enum.with_index(1)
      |> Enum.each(fn {{white, black, result}, board} ->
        Repo.insert!(%Pairing{
          round_id: round.id,
          board: board,
          white_player_id: white.id,
          black_player_id: black && black.id,
          result: result
        })
      end)
    end
  end

  defp reload(t), do: Repo.get!(Tournament, t.id)
end
