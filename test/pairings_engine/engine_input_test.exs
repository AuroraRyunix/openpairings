defmodule PairingsEngine.EngineInputTest do
  @moduledoc """
  What "Pair round" hands the engine, checked against the file a reference
  builds from the same tournament: starting ranks that are the pairing
  numbers, and unplayed rounds written with the letter for what they are
  worth, adding up to the score column.

  Each case is the smallest tournament showing one of the three input
  mistakes the app-path harness (bbpPairings and Ainalrami on an
  independently built TRF) found on 2026-10-02:

    * a late entrant ranked by rating inside the field instead of at its
      pairing number (harness seeds 19 and 20323), and 5.2.5's parity taken
      on those ranks recolouring a board of two players with no game yet
      (seed 2);
    * every unplayed round written `Z` while the engine was told a `Z` is
      worth the absence value, which gave the pairing-allocated bye to the
      wrong player (seed 1011);
    * with a loss worth more than 0, a late entrant's rounds before joining
      scored as losses (seeds 20140 and 20329).
  """

  use PairingsEngine.DataCase, async: true

  alias Ainalrami.Trf
  alias PairingsEngine.{Pairing, Repo, Tournaments}
  alias PairingsEngine.Tournaments.Tournament

  setup do
    handler = "engine-input-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:pairings_engine, :pairing, :trf_built],
      fn _event, _measurements, meta, _config ->
        Process.put({:trf, meta.round}, meta.trf)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  describe "starting ranks" do
    # Six players and a seventh, rated above all of them, who joins in round
    # 2 and is numbered 7 after the field. Round 1: 1, 2 and 3 win.
    setup do
      t = tournament(%{})
      players = add_players(t, [2400, 2300, 2200, 2100, 2000, 1900])
      {:ok, round1} = Pairing.pair_next_round(t)
      higher_wins(round1)

      {:ok, late} =
        Tournaments.create_player(t.id, %{
          "name" => "Late, Entrant",
          "fide_rating" => 2600,
          "start_round" => 2
        })

      %{t: t, players: players, late: late}
    end

    test "the engine's starting rank is the pairing number", %{t: t} do
      {:ok, _round2} = Pairing.pair_next_round(t)

      for row <- Trf.parse(Process.get({:trf, 2})).players do
        assert row.rank == pairing_number(t, row.name), "#{row.name} is rank #{row.rank}"
      end
    end

    # The round bbpPairings (`--dutch`) pairs from the file numbered by
    # pairing number, checked 2026-10-02. Ranked by rating, the late
    # entrant was the zero group's top player instead of its last.
    test "a late entrant takes their place in the score group by pairing number", %{t: t} do
      {:ok, round2} = Pairing.pair_next_round(t)
      assert board_numbers(t, round2) == [{2, 1}, {4, 3}, {6, 0}, {7, 5}]
    end
  end

  # Seed 2's shape: two players with no game yet meet, and 5.2.5 colours
  # their board by the parity of the higher-ranked one's starting rank. P7
  # sits round 1 out (an absence worth nothing) and P8 joins in round 2, so
  # both are on zero with no colour; ranked by rating, P8 (2600) went ahead
  # of the round-1 losers and moved every rank below it by one.
  test "5.2.5's parity is taken on the pairing numbers" do
    t = tournament(%{})
    add_players(t, [2400, 2300, 2200, 2100, 2000, 1900, 1800])
    p7 = player(t, 7)
    {:ok, _} = Tournaments.update_player(p7, %{"absent_rounds" => "1"})
    {:ok, round1} = Pairing.pair_next_round(t)
    higher_wins(round1)

    {:ok, _late} =
      Tournaments.create_player(t.id, %{
        "name" => "P8, Late",
        "fide_rating" => 2600,
        "start_round" => 2
      })

    {:ok, round2} = Pairing.pair_next_round(t)

    # bbpPairings (`--dutch`) on the file numbered by pairing number,
    # checked 2026-10-02: 6-8 is a board of two players with no colour, and
    # 6 is even, so 6 takes the other colour from the initial White.
    assert board_numbers(t, round2) == [{2, 1}, {4, 3}, {6, 8}, {7, 5}]
  end

  # The production report (2026-10-08): round 1, number 17 the highest
  # rated player in the field, number 16 absent - and 8-17 went out as
  # board 1, above 1-9, which is board order by rating. C.04.2 3.6 orders
  # boards by the higher-ranked player's score, the pair's sum, then the
  # higher-ranked player's TPN; in round 1 that is the TPN alone. The
  # numbers are written straight onto the players, as a TPN exchange or a
  # rating corrected after numbering leaves them.
  test "round 1's boards follow the TPN of the higher-ranked player, not the rating" do
    t = tournament(%{})
    players = add_players(t, Enum.map(1..16, &(2000 - &1)) ++ [2600])

    for {p, n} <- Enum.with_index(players, 1) do
      Repo.update_all(from(x in PairingsEngine.Tournaments.Player, where: x.id == ^p.id),
        set: [pairing_number: n]
      )
    end

    {:ok, _} = Tournaments.update_player(player(t, 16), %{"absent_rounds" => "1"})
    {:ok, round1} = Pairing.pair_next_round(t)

    pn = Map.new(Tournaments.list_players(t.id), &{&1.id, &1.pairing_number})

    boards =
      round1
      |> pairings()
      |> Enum.sort_by(& &1.board)
      |> Enum.map(&Enum.sort([pn[&1.white_player_id], pn[&1.black_player_id]]))

    assert boards == [[1, 9], [2, 10], [3, 11], [4, 12], [5, 13], [6, 14], [7, 15], [8, 17]]
  end

  describe "unplayed rounds" do
    # The tournament pays a full point for an absence, but not for the
    # rounds before a late entrant joined (`late_entry_absences` off).
    # Round 1: P6 absent, the other five play two boards and P5 gets the
    # pairing-allocated bye. P7 joins in round 2.
    setup do
      t = tournament(%{abs_value: 1.0, late_entry_absences: false})
      add_players(t, [2400, 2300, 2200, 2100, 2000, 1900])
      {:ok, _} = Tournaments.update_player(player(t, 6), %{"absent_rounds" => "1"})
      {:ok, round1} = Pairing.pair_next_round(t)
      higher_wins(round1)

      {:ok, late} =
        Tournaments.create_player(t.id, %{
          "name" => "P7, Late",
          "fide_rating" => 2250,
          "start_round" => 2
        })

      %{t: t, late: late}
    end

    test "each is written with the letter for what it is worth, adding up to the score", %{
      t: t
    } do
      {:ok, _round2} = Pairing.pair_next_round(t)
      parsed = Trf.parse(Process.get({:trf, 2}))
      by_name = Map.new(parsed.players, &{&1.name, &1})

      # The absence paid a full point: `F`, not a `Z` worth a point.
      assert hd(by_name[player(t, 6).name].games).result == "F"
      assert by_name[player(t, 6).name].points == 1.0
      # The round before joining paid nothing: `Z`, worth nothing.
      assert hd(by_name["P7, Late"].games).result == "Z"
      assert by_name["P7, Late"].points == 0.0

      assert_scores_add_up(parsed, Tournament.engine_point_system(t), 1)
    end
  end

  # The late-entry rule this app has (`PairingsEngine.LateEntry`): rounds
  # before joining count as absences, here half a point each but only
  # through round 1 (`abs_jusque`). Both keep their worth, and their letter
  # says it: round 1 `H`, round 2 `Z`.
  test "rounds before joining that count as absences keep their worth" do
    t = tournament(%{abs_value: 0.5, abs_jusque: 1, late_entry_absences: true})
    add_players(t, [2400, 2300, 2200, 2100])
    {:ok, round1} = Pairing.pair_next_round(t)
    higher_wins(round1)
    {:ok, round2} = Pairing.pair_next_round(t)
    higher_wins(round2)

    {:ok, _late} =
      Tournaments.create_player(t.id, %{
        "name" => "P5, Late",
        "fide_rating" => 2250,
        "start_round" => 3
      })

    {:ok, _round3} = Pairing.pair_next_round(t)
    parsed = Trf.parse(Process.get({:trf, 3}))
    late = Enum.find(parsed.players, &(&1.name == "P5, Late"))

    assert Enum.map(late.games, & &1.result) == ["H", "Z"]
    assert late.points == 0.5
    assert_scores_add_up(parsed, Tournament.engine_point_system(t), 2)

    [entry] =
      for e <- PairingsEngine.Standings.standings(t, through_round: 2),
          e.player.name == "P5, Late",
          do: e

    assert entry.points == 0.5
  end

  # Harness seed 1011: six players, three rounds, an absence worth a point,
  # and a seventh player joining in round 2 with `late_entry_absences` off,
  # so their round 1 is worth nothing. Told every `Z` was worth the
  # absence's point, the engine read the late entrant - last, on zero - as
  # having scored a point without playing, and gave round 3's bye to
  # somebody else.
  test "the pairing-allocated bye goes where the reference file puts it" do
    t =
      tournament(%{
        rounds_count: 3,
        initial_colour: "black",
        abs_value: 1.0,
        abs_jusque: 3,
        abs_nbfois: 1,
        late_entry_absences: false
      })

    add_players(t, [2525, 2246, 2179, 2138, 2103, 1243])
    {:ok, round1} = Pairing.pair_next_round(t)
    assert board_numbers(t, round1) == [{2, 5}, {4, 1}, {6, 3}]
    play(round1, %{{2, 5} => "1/2-1/2", {4, 1} => "1/2-1/2", {6, 3} => "1-0"})

    {:ok, _late} =
      Tournaments.create_player(t.id, %{
        "name" => "P7, Late",
        "fide_rating" => 2274,
        "start_round" => 2
      })

    {:ok, round2} = Pairing.pair_next_round(t)
    assert board_numbers(t, round2) == [{1, 6}, {3, 0}, {5, 4}, {7, 2}]
    play(round2, %{{1, 6} => "1/2-1/2", {5, 4} => "1/2-1/2", {7, 2} => "0-1"})

    {:ok, round3} = Pairing.pair_next_round(t)

    # bbpPairings (`--dutch`) and Ainalrami on the harness's reference file,
    # 2026-10-02.
    assert board_numbers(t, round3) == [{2, 6}, {3, 4}, {5, 1}, {7, 0}]
  end

  describe "a loss worth something" do
    # 3-2-1: a loss pays a point. Round 1 played by six; P7 joins in round 2
    # and P6 withdraws after round 1.
    setup do
      t =
        tournament(%{
          points_win: 3.0,
          points_draw: 2.0,
          points_loss: 1.0,
          bye_value: 3.0,
          abs_value: 3.0,
          late_entry_absences: false
        })

      add_players(t, [2400, 2300, 2200, 2100, 2000, 1900])
      {:ok, round1} = Pairing.pair_next_round(t)
      higher_wins(round1)
      {:ok, _} = Tournaments.update_player(player(t, 6), %{"status" => "withdrawn"})

      {:ok, _late} =
        Tournaments.create_player(t.id, %{
          "name" => "P7, Late",
          "fide_rating" => 2250,
          "start_round" => 2
        })

      {:ok, round2} = Pairing.pair_next_round(t)
      higher_wins(round2)
      %{t: t}
    end

    test "rounds before joining and after withdrawing score nothing", %{t: t} do
      {:ok, _round3} = Pairing.pair_next_round(t)
      parsed = Trf.parse(Process.get({:trf, 3}))
      by_name = Map.new(parsed.players, &{&1.name, &1})
      late = by_name["P7, Late"]
      withdrawn = by_name[player(t, 6).name]

      assert hd(late.games).result == "Z"
      # Round 1 nothing, round 2 a game - not a loss's point for round 1.
      assert late.points == Enum.at(late.games, 1) |> game_value(t)
      # Round 1 a loss (1 point), round 2 nothing.
      assert Enum.at(withdrawn.games, 1).result == "Z"
      assert withdrawn.points == 1.0

      assert_scores_add_up(parsed, Tournament.engine_point_system(t), 2)
    end

    test "the standings agree with the file's score column", %{t: t} do
      {:ok, _round3} = Pairing.pair_next_round(t)
      parsed = Trf.parse(Process.get({:trf, 3}))
      standings = PairingsEngine.Standings.standings(t, through_round: 2)

      for entry <- standings do
        row = Enum.find(parsed.players, &(&1.name == entry.player.name))
        assert row.points == entry.points, entry.player.name
      end
    end
  end

  ## helpers

  defp tournament(attrs) do
    Repo.insert!(
      struct(
        %Tournament{
          name: "Engine input",
          type: "swiss",
          rounds_count: 5,
          initial_colour: "white",
          # Every case here is a harness seed whose reference file numbered
          # the late entrant after the field (2026-10-02, before "rating"
          # became the default). By rating, the late entrant's pairing number
          # and rating order coincide, and the starting-rank cases could no
          # longer tell the two apart - which is the whole point of them.
          late_entry_numbering: "after"
        },
        attrs
      )
    )
  end

  defp add_players(t, ratings) do
    for {rating, n} <- Enum.with_index(ratings, 1) do
      {:ok, p} =
        Tournaments.create_player(t.id, %{"name" => "P#{n}, Field", "fide_rating" => rating})

      p
    end
  end

  # The player numbered `n` - the field is numbered by rating at round 1.
  defp player(t, n) do
    name = "P#{n}, Field"
    Enum.find(Tournaments.list_players(t.id), &(&1.name == name))
  end

  defp pairing_number(t, name),
    do: Enum.find(Tournaments.list_players(t.id), &(&1.name == name)).pairing_number

  defp pairings(round), do: Repo.preload(round, :pairings, force: true).pairings

  defp board_numbers(t, round) do
    pn = Map.new(Tournaments.list_players(t.id), &{&1.id, &1.pairing_number})

    round
    |> pairings()
    |> Enum.map(&{pn[&1.white_player_id], Map.get(pn, &1.black_player_id, 0)})
    |> Enum.sort()
  end

  # The higher pairing number... the LOWER number (the higher seed) wins
  # every board.
  defp higher_wins(round) do
    pn =
      Map.new(Tournaments.list_players(round.tournament_id), &{&1.id, &1.pairing_number})

    for p <- pairings(round), p.black_player_id do
      result = if pn[p.white_player_id] < pn[p.black_player_id], do: "1-0", else: "0-1"
      {:ok, _} = Tournaments.update_pairing_result(p, result)
    end
  end

  # `results` by `{white, black}` pairing numbers.
  defp play(round, results) do
    pn =
      Map.new(Tournaments.list_players(round.tournament_id), &{&1.id, &1.pairing_number})

    for p <- pairings(round), p.black_player_id do
      result = Map.fetch!(results, {pn[p.white_player_id], pn[p.black_player_id]})
      {:ok, _} = Tournaments.update_pairing_result(p, result)
    end
  end

  defp game_value(%{result: code}, t) do
    points = Tournament.engine_point_system(t)
    Map.fetch!(values(points), code)
  end

  # What bbpPairings checks before it pairs: every row's score column is
  # the sum of its rounds at the file's point system.
  defp assert_scores_add_up(parsed, points, rounds_played) do
    for row <- parsed.players do
      sum =
        row.games
        # A column for the round being paired (a player left out of it) is
        # not in the score.
        |> Enum.take(rounds_played)
        |> Enum.map(&Map.fetch!(values(points), &1.result))
        |> Enum.sum()

      assert_in_delta sum, row.points, 0.001, "#{row.name}: #{inspect(row.games)}"
    end
  end

  defp values(points) do
    %{
      "1" => points.win,
      "+" => points.win,
      "W" => points.win,
      "F" => points.win,
      "=" => points.draw,
      "D" => points.draw,
      "H" => points.draw,
      "0" => points.loss,
      "L" => points.loss,
      "-" => points.forfeit_loss,
      "U" => points.pairing_allocated_bye,
      "Z" => points.zero_point_bye
    }
  end
end
