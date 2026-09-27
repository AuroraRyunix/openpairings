defmodule PairingsEngine.ExtraPointsPairingTest do
  @moduledoc """
  The two kinds of extra points (docs/extra-points.md) as the pairing sees
  them. Each test pairs a real round through Ainalrami - no jar needed - and
  checks the score groups actually moved, not only that a line was written:

    * a counted handicap puts players in the score group of their total, so
      the players carrying the head start meet each other;
    * acceleration hands the engine virtual points every round - round 1
      then pairs the top half against the top half - whether or not the
      standings keep them;
    * the virtual points each round was paired with are recorded, so a
      part-way reduction changes the next round and not the history;
    * the FIDE report keeps a handicap out and an acceleration in.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Pairing, Repo, Standings, Tournaments, TrfExport}
  alias PairingsEngine.Tournaments.Tournament

  defp tournament(attrs) do
    Repo.insert!(
      struct(
        %Tournament{
          name: "Extra points",
          type: "swiss",
          rounds_count: 5,
          tiebreaks: ~w(BH),
          pairing_engine: "ainalrami",
          initial_colour: "white",
          round_dates: List.duplicate("2026-09-01", 5)
        },
        attrs
      )
    )
  end

  # P1..P8, rated 2000 down to 1650, so the pairing numbers are 1..8 in name
  # order. `extra` gives player n that many extra points.
  defp roster(t, extra \\ %{}) do
    for n <- 1..8 do
      {:ok, p} =
        Tournaments.create_player(t.id, %{
          "name" => "P#{n}",
          "fide_rating" => 2050 - n * 50,
          "extra_points" => Map.get(extra, n, 0.0)
        })

      p
    end
  end

  # The boards as unordered pairs of names, so colours don't matter.
  defp pairs(round) do
    names = Map.new(Tournaments.list_players(round.tournament_id), &{&1.id, &1.name})

    round
    |> Repo.preload(:pairings, force: true)
    |> Map.fetch!(:pairings)
    |> Enum.map(fn p -> MapSet.new([names[p.white_player_id], names[p.black_player_id]]) end)
    |> MapSet.new()
  end

  defp pairs_of(list), do: list |> Enum.map(&MapSet.new/1) |> MapSet.new()

  # 1-0 on every board, white wins.
  defp white_wins(round) do
    round
    |> Repo.preload(:pairings, force: true)
    |> Map.fetch!(:pairings)
    |> Enum.each(fn p -> {:ok, _} = Tournaments.update_pairing_result(p, "1-0") end)
  end

  defp plain, do: pairs_of([~w(P1 P5), ~w(P2 P6), ~w(P3 P7), ~w(P4 P8)])
  defp halves, do: pairs_of([~w(P1 P3), ~w(P2 P4), ~w(P5 P7), ~w(P6 P8)])

  test "without extra points round 1 is the ordinary top-half-against-bottom-half pairing" do
    t = tournament(%{})
    roster(t)
    assert {:ok, round} = Pairing.pair_next_round(t)
    assert pairs(round) == plain()
    assert round.virtual_points == %{}
  end

  describe "handicap" do
    test "counted, the head start is in the score the engine groups by" do
      # The four lowest-rated start a point up: on totals they are a score
      # group of their own, and play each other.
      t = tournament(%{extra_points_mode: "handicap", count_extra_points: true})
      players = roster(t, %{5 => 1.0, 6 => 1.0, 7 => 1.0, 8 => 1.0})

      assert {:ok, round} = Pairing.pair_next_round(t)
      assert pairs(round) == halves()

      # And the round records what it was paired with.
      ids = players |> Enum.drop(4) |> Map.new(&{to_string(&1.id), 1.0})
      assert round.virtual_points == ids
    end

    test "the leader on handicap meets the chasers in round 2" do
      # P8 starts 1.5 up and loses round 1. On game points P8 has nothing and
      # would meet another loser; on the total P8 leads the field, so it is
      # the round-1 winners - the players chasing that total - P8 meets.
      t = tournament(%{extra_points_mode: "handicap", count_extra_points: true})
      roster(t, %{8 => 1.5})
      names = Map.new(Tournaments.list_players(t.id), &{&1.id, &1.name})

      {:ok, r1} = Pairing.pair_next_round(t)

      r1
      |> Repo.preload(:pairings, force: true)
      |> Map.fetch!(:pairings)
      |> Enum.each(fn p ->
        result = if names[p.white_player_id] == "P8", do: "0-1", else: "1-0"
        {:ok, _} = Tournaments.update_pairing_result(p, result)
      end)

      assert {:ok, r2} = Pairing.pair_next_round(Repo.reload!(t))

      standings =
        t |> Repo.reload!() |> Standings.standings() |> Map.new(&{&1.player.name, &1})

      p8_board =
        r2
        |> Repo.preload(:pairings, force: true)
        |> Map.fetch!(:pairings)
        |> Enum.find(&("P8" in [names[&1.white_player_id], names[&1.black_player_id]]))

      opponent =
        if names[p8_board.white_player_id] == "P8",
          do: names[p8_board.black_player_id],
          else: names[p8_board.white_player_id]

      assert standings["P8"].points == 0.0
      assert standings["P8"].total == 1.5
      assert standings[opponent].points == 1.0
    end

    test "not counted, it does nothing - the pairing is the plain one" do
      t = tournament(%{extra_points_mode: "handicap", count_extra_points: false})
      roster(t, %{5 => 1.0, 6 => 1.0, 7 => 1.0, 8 => 1.0})

      assert {:ok, round} = Pairing.pair_next_round(t)
      assert pairs(round) == plain()
      assert round.virtual_points == %{}
    end

    test "the FIDE report keeps game points and leaves the handicap out of 250/XXA" do
      t = tournament(%{extra_points_mode: "handicap", count_extra_points: true})
      roster(t, %{5 => 1.0, 6 => 1.0, 7 => 1.0, 8 => 1.0})
      {:ok, r1} = Pairing.pair_next_round(t)
      white_wins(r1)

      assert {:ok, text} = TrfExport.export(Repo.reload!(t))
      refute text =~ "\r\n250"
      refute text =~ "XXA"
      # Game points in 001 - one round played, so 0 or 1 and never the
      # total - and the head start in the 299 record.
      assert text =~ "\r\n299"

      assert text
             |> Ainalrami.Trf.parse()
             |> Map.fetch!(:players)
             |> Enum.all?(&(&1.points in [0.0, 1.0]))

      assert {:ok, engine} = TrfExport.export(Repo.reload!(t), nil, dialect: :engine)
      refute engine =~ "XXA"
    end
  end

  describe "acceleration" do
    test "round 1 pairs the top half against the top half, whatever the standings keep" do
      t = tournament(%{extra_points_mode: "acceleration", count_extra_points: false})
      roster(t, %{1 => 1.0, 2 => 1.0, 3 => 1.0, 4 => 1.0})

      assert {:ok, round} = Pairing.pair_next_round(t)
      assert pairs(round) == halves()

      # Kept out of the standings: they rank on game points alone.
      white_wins(round)
      entries = t |> Repo.reload!() |> Standings.standings()
      assert Enum.all?(entries, &(Standings.rank_score(&1, Repo.reload!(t)) == &1.points))
    end

    @tag :javafo
    test "JaVaFo reads them too: the same top-half-against-top-half round 1" do
      t =
        tournament(%{extra_points_mode: "acceleration", pairing_engine: "javafo"})

      roster(t, %{1 => 1.0, 2 => 1.0, 3 => 1.0, 4 => 1.0})

      assert {:ok, round} = Pairing.pair_next_round(t)
      assert pairs(round) == halves()
    end

    @tag :javafo
    test "JaVaFo pairs a counted handicap on the total as well" do
      t =
        tournament(%{
          extra_points_mode: "handicap",
          count_extra_points: true,
          pairing_engine: "javafo"
        })

      roster(t, %{5 => 1.0, 6 => 1.0, 7 => 1.0, 8 => 1.0})

      assert {:ok, round} = Pairing.pair_next_round(t)
      assert pairs(round) == halves()
    end

    test "kept in the standings, they rank on the total, as SWAR does" do
      t = tournament(%{extra_points_mode: "acceleration", count_extra_points: true})
      roster(t, %{8 => 3.0})
      {:ok, r1} = Pairing.pair_next_round(t)
      white_wins(r1)

      [first | _] = t |> Repo.reload!() |> Standings.standings()
      assert first.player.name == "P8"
    end

    test "a part-way reduction reaches the next round; the history keeps what was used" do
      t = tournament(%{extra_points_mode: "acceleration"})
      [p1 | _] = roster(t, %{1 => 1.0, 2 => 1.0, 3 => 1.0, 4 => 1.0})

      {:ok, r1} = Pairing.pair_next_round(t)
      white_wins(r1)

      assert {:ok, %{changed: 4}} = Tournaments.reduce_extra_points(t, 0, 3000)
      assert Tournaments.get_player!(t.id, p1.id).extra_points == 0.5

      # Round 1 was paired on 1.0 and round 2 will be on 0.5: the XXA line
      # carries both, round by round.
      trf = Pairing.javafo_input(Repo.reload!(t))
      assert trf =~ ~r/^XXA\s+1\s+1\.0\s+0\.5\s*$/m

      {:ok, r2} = Pairing.pair_next_round(Repo.reload!(t))
      assert r2.virtual_points[to_string(p1.id)] == 0.5
      assert Repo.reload!(r1).virtual_points[to_string(p1.id)] == 1.0

      # Taken to nothing, a player drops out of the next round's values but
      # keeps the history.
      {:ok, _} = Tournaments.reduce_extra_points(t, 0, 3000)
      assert Tournaments.get_player!(t.id, p1.id).extra_points == 0.0
      assert {:ok, %{changed: 0}} = Tournaments.reduce_extra_points(t, 0, 3000)
    end

    test "the FIDE report carries them as 250 records, the engine dialect as XXA" do
      t = tournament(%{extra_points_mode: "acceleration"})
      roster(t, %{1 => 1.0, 2 => 1.0})
      {:ok, r1} = Pairing.pair_next_round(t)
      white_wins(r1)

      assert {:ok, text} = TrfExport.export(Repo.reload!(t))
      assert text =~ "\r\n250       1.0   1   1    1    2\r\n"

      assert {:ok, engine} = TrfExport.export(Repo.reload!(t), nil, dialect: :engine)
      assert engine =~ ~r/^XXA\s+1\s+1\.0\s*$/m
    end

    test "a JSON backup carries the recorded virtual points, re-keyed to the new players" do
      t = tournament(%{extra_points_mode: "acceleration"})
      roster(t, %{1 => 1.0})
      {:ok, _r1} = Pairing.pair_next_round(t)

      user =
        Repo.insert!(%PairingsEngine.Accounts.User{
          email: "user#{System.unique_integer([:positive])}@example.com",
          confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
        })

      payload =
        t
        |> Repo.reload!()
        |> PairingsEngine.TournamentExport.export_tournament()
        |> Jason.encode!()
        |> Jason.decode!()

      assert {:ok, [copy]} =
               PairingsEngine.TournamentImport.import(
                 payload,
                 PairingsEngine.Accounts.Scope.for_user(user)
               )

      p1 = copy.id |> Tournaments.list_players() |> Enum.find(&(&1.name == "P1"))
      assert Repo.reload!(copy).extra_points_mode == "acceleration"
      assert Tournaments.get_round(copy.id, 1).virtual_points == %{to_string(p1.id) => 1.0}
    end

    test "a penalty (negative extra points) counts in the standings but never reaches XXA" do
      # JaVaFo cannot read a negative XXA value - it dies on "0-1.0" - so
      # virtual points stop at zero, for both engines.
      # The Players form refuses a negative value; an import (a TRF26 `299`
      # penalty, a SWAR round record) is how one arrives.
      t = tournament(%{extra_points_mode: "acceleration", count_extra_points: true})
      [p1 | _] = roster(t, %{2 => 1.0})
      p1 |> Ecto.Changeset.change(extra_points: -1.0) |> Repo.update!()

      {:ok, r1} = Pairing.pair_next_round(t)
      refute Map.has_key?(r1.virtual_points, to_string(p1.id))
      white_wins(r1)

      trf = Pairing.javafo_input(Repo.reload!(t))
      refute trf =~ "-1.0"
      refute trf =~ ~r/^XXA\s+1\s/m

      entry = t |> Repo.reload!() |> Standings.standings() |> Enum.find(&(&1.player.id == p1.id))
      assert entry.total == entry.points - 1.0
    end

    test "players with none of their own are not given a line" do
      t = tournament(%{extra_points_mode: "acceleration"})
      roster(t, %{1 => 1.0})
      {:ok, r1} = Pairing.pair_next_round(t)
      white_wins(r1)

      trf = Pairing.javafo_input(Repo.reload!(t))
      assert trf =~ ~r/^XXA\s+1\s/m
      refute trf =~ ~r/^XXA\s+2\s/m
    end
  end

  describe "exclusive with Baku" do
    test "Baku cannot be turned on over acceleration mode, nor over a counted handicap" do
      t = tournament(%{extra_points_mode: "acceleration"})
      assert {:error, cs} = Tournaments.update_tournament(t, %{"acceleration" => "baku"})
      assert cs.errors[:acceleration]

      t = tournament(%{extra_points_mode: "handicap", count_extra_points: true})
      assert {:error, _} = Tournaments.update_tournament(t, %{"acceleration" => "baku"})

      t = tournament(%{extra_points_mode: "handicap", count_extra_points: false})
      assert {:ok, t} = Tournaments.update_tournament(t, %{"acceleration" => "baku"})

      assert {:error, cs} =
               Tournaments.update_tournament(t, %{"extra_points_mode" => "acceleration"})

      assert cs.errors[:extra_points_mode]
    end

    test "a row holding both anyway pairs on Baku alone" do
      t =
        tournament(%{extra_points_mode: "acceleration", acceleration: "baku"})

      players = roster(t, %{8 => 5.0})
      refute Tournament.extra_points_pairing?(t)

      accelerations = Pairing.accelerations(t, players, 1)
      refute Map.has_key?(accelerations, List.last(players).id)
    end
  end

  describe "bands" do
    test "acceleration pays at or above a rating, the highest band that fits" do
      {:ok, bands} = Tournament.parse_extra_points_bands("1800:0.5, 2000:1")
      assert Tournament.band_extra_points(bands, 2100, "acceleration") == 1.0
      assert Tournament.band_extra_points(bands, 2000, "acceleration") == 1.0
      assert Tournament.band_extra_points(bands, 1999, "acceleration") == 0.5
      assert Tournament.band_extra_points(bands, 1700, "acceleration") == 0.0
      assert Tournament.band_extra_points(bands, 0, "acceleration") == 0.0

      {:ok, with_zero} = Tournament.parse_extra_points_bands("0:0.5, 2000:1")
      assert Tournament.band_extra_points(with_zero, 0, "acceleration") == 0.5
    end

    test "handicap pays below a rating, as it always did" do
      {:ok, bands} = Tournament.parse_extra_points_bands("1400:1, 1600:0.5")
      assert Tournament.band_extra_points(bands, 1350, "handicap") == 1.0
      assert Tournament.band_extra_points(bands, 1550, "handicap") == 0.5
      assert Tournament.band_extra_points(bands, 1700, "handicap") == 0.0
    end

    test "\"Apply bands to players\" follows the mode" do
      t = tournament(%{extra_points_mode: "acceleration", extra_points_bands: "1900:1"})
      roster(t)

      assert {:ok, %{matched: 3}} = Tournaments.apply_extra_points_bands(t)

      by_name = Map.new(Tournaments.list_players(t.id), &{&1.name, &1.extra_points})
      assert by_name["P1"] == 1.0
      assert by_name["P3"] == 1.0
      assert by_name["P4"] == 0.0
    end
  end
end
