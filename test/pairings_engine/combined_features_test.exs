defmodule PairingsEngine.CombinedFeaturesTest do
  @moduledoc """
  Three features that each change a score or a pairing input, in one
  tournament: a late entrant whose join round is worked out (rounds before
  it count as absences), acceleration extra points handed to the engine as
  virtual points, and an organiser's bye exclusion. Whatever each does on
  its own, together they have to agree everywhere a score is read: the
  standings, the score the next round is paired on, the TRF report's `001`
  totals and the SWAR file. Ainalrami only, so no JVM.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{LateEntry, Pairing, Repo, Standings, Tournaments, TrfExport}
  alias PairingsEngine.Federations.BEL.{SwarExport, SwarImport}
  alias PairingsEngine.Tournaments.Tournament

  defp tournament do
    Repo.insert!(%Tournament{
      name: "Combined",
      type: "swiss",
      pairing_system: "swiss",
      pairing_engine: "ainalrami",
      rounds_count: 6,
      round_dates: List.duplicate("2026-09-01", 6),
      tiebreaks: ~w(BH),
      initial_colour: "white",
      abs_value: 0.5,
      abs_nbfois: 3,
      abs_jusque: 9,
      extra_points_mode: "acceleration",
      count_extra_points: true
    })
  end

  # Seven players, so every round has a pairing-allocated bye; the two
  # strongest accelerated, the weakest excluded from the bye.
  defp roster(t) do
    for n <- 1..7 do
      attrs = %{
        "name" => "P#{n}",
        "fide_rating" => 2100 - n * 50,
        "extra_points" => if(n <= 2, do: 1.0, else: 0.0)
      }

      attrs = if n == 7, do: Map.merge(attrs, %{"no_bye" => "true"}), else: attrs
      {:ok, p} = Tournaments.create_player(t.id, attrs)
      p
    end
  end

  # The higher-rated player wins every game.
  defp play(round) do
    rating = Map.new(Tournaments.list_players(round.tournament_id), &{&1.id, &1.fide_rating})

    round
    |> Repo.preload(:pairings, force: true)
    |> Map.fetch!(:pairings)
    |> Enum.filter(& &1.black_player_id)
    |> Enum.each(fn p ->
      result = if rating[p.white_player_id] > rating[p.black_player_id], do: "1-0", else: "0-1"
      {:ok, _} = Tournaments.update_pairing_result(p, result)
    end)
  end

  defp bye_holder(round) do
    round
    |> Repo.preload(:pairings, force: true)
    |> Map.fetch!(:pairings)
    |> Enum.find_value(fn p -> if is_nil(p.black_player_id), do: p.white_player_id end)
  end

  # Standings, pairing input and TRF 001 all give each player the same
  # game-point score.
  defp assert_consistent(t) do
    t = Repo.reload!(t)
    players = Tournaments.list_players(t.id)
    standings = Map.new(Standings.standings(t), &{&1.player.id, &1})
    input = t |> Pairing.trf_player_rows(players) |> Map.new(&{&1.id, &1})

    {:ok, trf} = TrfExport.export(t)
    lines = trf |> String.split(["\r\n", "\n"]) |> Enum.filter(&String.starts_with?(&1, "001"))

    # A player is numbered when first paired; until then there is no TRF
    # row to compare, only the standings.
    for p <- players, p.pairing_number != nil do
      points = Map.fetch!(standings, p.id).points
      assert Map.fetch!(input, p.id).points == points, "#{p.name}: pairing input vs standings"

      line = Enum.find(lines, &(&1 =~ p.name))
      assert line, "#{p.name}: no 001 line"

      assert line |> String.slice(80, 4) |> String.trim() |> Float.parse() |> elem(0) == points,
             "#{p.name}: TRF 001 total vs standings"
    end

    standings
  end

  test "a late entrant, extra points and a bye exclusion score and pair consistently" do
    t = tournament()
    players = roster(t)
    p7 = List.last(players)

    for _n <- 1..3 do
      assert {:ok, round} = Pairing.pair_next_round(Repo.reload!(t))
      refute bye_holder(round) == p7.id, "the excluded player got the bye"
      assert round.virtual_points != %{}
      play(round)
    end

    # The first round already had extra points and an exclusion in force.
    assert Repo.reload!(t).fide_compliance_lost_round == 1

    # Added after round 3 the old way: no join round set.
    {:ok, late} = Tournaments.create_player(t.id, %{"name" => "Late", "fide_rating" => "1500"})
    assert late.start_round == 1
    assert LateEntry.effective_start_rounds(t)[late.id] == {4, :next_round}

    standings = assert_consistent(t)
    assert standings[late.id].points == 1.5

    # Round 4: eight players, the late entrant among them.
    assert {:ok, r4} = Pairing.pair_next_round(Repo.reload!(t))

    seated =
      r4
      |> Repo.preload(:pairings)
      |> Map.fetch!(:pairings)
      |> Enum.flat_map(&[&1.white_player_id, &1.black_player_id])

    assert late.id in seated
    play(r4)

    standings = assert_consistent(t)
    assert LateEntry.effective_start_rounds(t)[late.id] == {4, :first_game}

    # Extra points count in the total, not in the game points.
    p1 = hd(players)
    assert standings[p1.id].total == standings[p1.id].points + 1.0

    # The SWAR file carries the late entrant's three absences and their game.
    {:ok, parsed} = t.id |> SwarExport.export() |> SwarImport.parse()
    swar_late = Enum.find(parsed.players, &(&1.name == "Late"))

    assert swar_late.rounds |> Enum.take(3) |> Enum.map(& &1.table) ==
             List.duplicate(0x4000, 3)

    assert swar_late.points == round(standings[late.id].points * 4)
  end
end
