defmodule PairingsEngine.KeizerTest do
  # SQLite sandbox flake with concurrent test processes - keep this serial,
  # per project convention for DB-touching test files.
  use PairingsEngine.DataCase, async: false

  import Ecto.Query

  alias PairingsEngine.{Keizer, Pairing, Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Tournament}

  ## ---------- helpers ----------

  defp player(id, name, rating, attrs \\ %{}) do
    struct(
      %Player{
        id: id,
        name: name,
        fide_rating: rating,
        start_round: 1,
        absent: false,
        absent_rounds: ""
      },
      attrs
    )
  end

  defp insert_player(tournament, name, attrs) do
    defaults = %{tournament_id: tournament.id, name: name}
    {:ok, player} = Tournaments.create_player(tournament.id, Map.merge(defaults, Map.new(attrs)))
    player
  end

  ## ---------- ladder values ----------

  describe "effective_top_value/2" do
    test "automatic (nil) is 2x the player count" do
      assert Keizer.effective_top_value(nil, 4) == 8
      assert Keizer.effective_top_value(nil, 10) == 20
    end

    test "an explicit top value is used as-is when it's already big enough" do
      assert Keizer.effective_top_value(50, 4) == 50
    end

    test "an explicit (or automatic) top value is floored at n + 1 so the bottom rung stays positive" do
      # 2 players, top forced down to 1 - floored to n + 1 = 3.
      assert Keizer.effective_top_value(1, 2) == 3
      # Automatic with a single player: 2*1 = 2, still floored to n + 1 = 2 (no-op here).
      assert Keizer.effective_top_value(nil, 1) == 2
    end
  end

  describe "initial_order/1 and assign_values/2" do
    test "initial order is rating descending, name ascending on ties" do
      a = player(1, "A", 2000)
      b = player(2, "B", 1800)
      c = player(3, "C", 1800)
      d = player(4, "D", 1600)

      order = Keizer.initial_order([d, c, b, a])
      assert Enum.map(order, & &1.id) == [a.id, b.id, c.id, d.id]
    end

    test "the top value decreases by 1 per rank" do
      order = [
        player(1, "A", 2000),
        player(2, "B", 1800),
        player(3, "C", 1600),
        player(4, "D", 1400)
      ]

      values = Keizer.assign_values(order, 8)

      assert values == %{1 => 8, 2 => 7, 3 => 6, 4 => 5}
    end
  end

  ## ---------- scoring fractions (score_round/5, no DB) ----------

  describe "score_round/5 - win/draw/loss" do
    setup do
      a = player(1, "A", 2000)
      b = player(2, "B", 1800)
      values = %{1 => 8, 2 => 7}
      {:ok, a: a, b: b, values: values}
    end

    test "a win is worth the opponent's current value", %{a: a, b: b, values: values} do
      games = %{1 => [%{round: 1, white_id: a.id, black_id: b.id, result: "1-0"}]}
      entry = Keizer.score_round(a, 1, games, %{}, values)
      assert entry == %{round: 1, class: :win, points: 7, opponent_id: b.id}
    end

    test "a loss is worth 0", %{a: a, b: b, values: values} do
      games = %{1 => [%{round: 1, white_id: a.id, black_id: b.id, result: "1-0"}]}
      entry = Keizer.score_round(b, 1, games, %{}, values)
      assert entry == %{round: 1, class: :loss, points: 0.0, opponent_id: a.id}
    end

    test "a draw is worth half the opponent's current value", %{a: a, b: b, values: values} do
      games = %{1 => [%{round: 1, white_id: a.id, black_id: b.id, result: "1/2-1/2"}]}
      assert Keizer.score_round(a, 1, games, %{}, values).points == 3.5
      assert Keizer.score_round(b, 1, games, %{}, values).points == 4.0
    end

    test "VCL.13's asymmetric \"1/2-0\" scores the ½ side like a draw, the 0 side like a loss", %{
      a: a,
      b: b,
      values: values
    } do
      games = %{1 => [%{round: 1, white_id: a.id, black_id: b.id, result: "1/2-0"}]}

      white_entry = Keizer.score_round(a, 1, games, %{}, values)
      assert white_entry.class == :half_win
      assert white_entry.points == 3.5

      black_entry = Keizer.score_round(b, 1, games, %{}, values)
      assert black_entry.class == :half_loss
      assert black_entry.points == 0.0
    end
  end

  describe "score_round/5 - forfeits, played 0-0, and rounds before joining" do
    setup do
      a = player(1, "A", 2000)
      b = player(2, "B", 1800)
      values = %{1 => 8, 2 => 7}
      {:ok, a: a, b: b, values: values}
    end

    test "a forfeit win is worth half your own value (no game played, same as a bye)", %{
      a: a,
      b: b,
      values: values
    } do
      games = %{1 => [%{round: 1, white_id: a.id, black_id: b.id, result: "1-0FF"}]}
      entry = Keizer.score_round(a, 1, games, %{}, values)
      assert entry.class == :forfeit_win
      assert entry.points == 4.0
    end

    test "a forfeit loss is worth 0", %{a: a, b: b, values: values} do
      games = %{1 => [%{round: 1, white_id: a.id, black_id: b.id, result: "1-0FF"}]}
      entry = Keizer.score_round(b, 1, games, %{}, values)
      assert entry.class == :forfeit_loss
      assert entry.points == 0.0
    end

    test "a double forfeit is worth 0 for both sides", %{a: a, b: b, values: values} do
      games = %{1 => [%{round: 1, white_id: a.id, black_id: b.id, result: "0-0FF"}]}
      assert Keizer.score_round(a, 1, games, %{}, values).points == 0.0
      assert Keizer.score_round(b, 1, games, %{}, values).points == 0.0
    end

    test "a played 0-0 (both lose) is worth 0 for both sides", %{a: a, b: b, values: values} do
      games = %{1 => [%{round: 1, white_id: a.id, black_id: b.id, result: "0-0"}]}
      assert Keizer.score_round(a, 1, games, %{}, values).points == 0.0
      assert Keizer.score_round(b, 1, games, %{}, values).points == 0.0
    end

    test "a round before start_round is worth 0", %{values: values} do
      late = player(3, "Late", 1700, %{start_round: 3})
      entry = Keizer.score_round(late, 2, %{}, %{}, values)
      assert entry == %{round: 2, class: :not_joined, points: 0.0, opponent_id: nil}
    end
  end

  describe "score_round/5 - byes and excused absences" do
    setup do
      a = player(1, "A", 2000)
      values = %{1 => 8}
      {:ok, a: a, values: values}
    end

    test "an unpaired (odd-count) bye is worth half your own value", %{a: a, values: values} do
      games = %{1 => [%{round: 1, white_id: a.id, black_id: nil, result: "bye"}]}
      entry = Keizer.score_round(a, 1, games, %{}, values)
      assert entry == %{round: 1, class: :unpaired_bye, points: 4.0, opponent_id: nil}
    end

    test "a 'pairing-allocated' byes-row is the same half-value bucket", %{a: a, values: values} do
      byes = %{1 => [%{round: 1, player_id: a.id, type: "pairing-allocated"}]}
      entry = Keizer.score_round(a, 1, %{}, byes, values)
      assert entry.class == :unpaired_bye
      assert entry.points == 4.0
    end

    test "a 'requested-zero' byes-row is an excused absence: a third of your own value", %{
      a: a,
      values: values
    } do
      byes = %{1 => [%{round: 1, player_id: a.id, type: "requested-zero"}]}
      entry = Keizer.score_round(a, 1, %{}, byes, values)
      assert entry.class == :excused
      assert_in_delta entry.points, 8 / 3, 1.0e-9
    end

    test "the permanent 'absent' flag is an excused absence even with no byes row", %{
      values: values
    } do
      absent = player(1, "A", 2000, %{absent: true})
      entry = Keizer.score_round(absent, 1, %{}, %{}, values)
      assert entry.class == :excused
      assert_in_delta entry.points, 8 / 3, 1.0e-9
    end

    test "a round listed in absent_rounds is an excused absence", %{values: values} do
      sometimes = player(1, "A", 2000, %{absent_rounds: "2,4"})
      assert Keizer.score_round(sometimes, 2, %{}, %{}, values).class == :excused
      assert Keizer.score_round(sometimes, 1, %{}, %{}, values).class == :zero
    end
  end

  ## ---------- hand-computed ladder values + retroactive recalculation ----------

  describe "recalculate/5 - hand-computed values and retroactive recalculation" do
    # A(2000) B(1900) C(1800) D(1700). Round 1: A beats B, C beats D
    # (both decisive - this fixture stays clear of the drawn-game
    # oscillation exercised separately below). n = 4, automatic top = 8.
    test "round 1 alone: a loser's fall changes the WINNER's already-recorded points" do
      a = player(1, "A", 2000)
      b = player(2, "B", 1900)
      c = player(3, "C", 1800)
      d = player(4, "D", 1700)

      games = [
        %{round: 1, white_id: a.id, black_id: b.id, result: "1-0"},
        %{round: 1, white_id: c.id, black_id: d.id, result: "1-0"}
      ]

      result = Keizer.recalculate([a, b, c, d], games, [], nil, 1)

      # B loses and C wins, so C leapfrogs B on the ladder despite B's
      # higher initial rating - the ranking genuinely changed order, so
      # this took more than 1 iteration (retroactive recalculation, not
      # just the initial rating order).
      assert Enum.map(result.order, & &1.id) == [a.id, c.id, b.id, d.id]
      assert result.iterations > 1
      assert result.values == %{a.id => 8, c.id => 7, b.id => 6, d.id => 5}

      # A's win over B is worth B's *current* (post-recalculation) value -
      # 6, not the 7 B started with - because B fell to 3rd.
      scored_a = Map.fetch!(result.scored, a.id)
      assert scored_a.points == 6.0

      assert [%{round: 1, class: :win, points: points, opponent_id: opponent_id}] =
               scored_a.rounds

      assert points == 6.0
      assert opponent_id == b.id
    end

    test "adding round 2 retroactively increases the value of A's round-1 win, because B climbs back up" do
      a = player(1, "A", 2000)
      b = player(2, "B", 1900)
      c = player(3, "C", 1800)
      d = player(4, "D", 1700)

      games = [
        %{round: 1, white_id: a.id, black_id: b.id, result: "1-0"},
        %{round: 1, white_id: c.id, black_id: d.id, result: "1-0"},
        %{round: 2, white_id: a.id, black_id: c.id, result: "1-0"},
        %{round: 2, white_id: b.id, black_id: d.id, result: "1-0"}
      ]

      after_r1 = Keizer.recalculate([a, b, c, d], games, [], nil, 1)
      after_r2 = Keizer.recalculate([a, b, c, d], games, [], nil, 2)

      round1_value_after_r1 =
        after_r1.scored |> Map.fetch!(a.id) |> Map.fetch!(:rounds) |> hd() |> Map.fetch!(:points)

      round1_entry_after_r2 = after_r2.scored |> Map.fetch!(a.id) |> Map.fetch!(:rounds) |> hd()

      assert round1_value_after_r1 == 6.0
      # B won round 2 and reclaimed 2nd place (tied with C on points, but
      # ahead on the rating tiebreak), so B's ladder value is back to 7 -
      # and A's round-1 win is rescored against that higher value.
      assert Enum.map(after_r2.order, & &1.id) == [a.id, b.id, c.id, d.id]
      assert round1_entry_after_r2.points == 7.0
      assert round1_entry_after_r2.points > round1_value_after_r1
    end
  end

  describe "recalculate/5 - determinism" do
    test "the same inputs always produce the same order, values and points" do
      a = player(1, "A", 2000)
      b = player(2, "B", 1900)
      c = player(3, "C", 1800)
      d = player(4, "D", 1700)

      games = [
        %{round: 1, white_id: a.id, black_id: c.id, result: "0-1"},
        %{round: 1, white_id: b.id, black_id: d.id, result: "1/2-1/2"}
      ]

      r1 = Keizer.recalculate([a, b, c, d], games, [], nil, 1)
      r2 = Keizer.recalculate([d, a, c, b], games, [], nil, 1)

      assert Enum.map(r1.order, & &1.id) == Enum.map(r2.order, & &1.id)
      assert r1.values == r2.values

      assert Map.new(r1.scored, fn {k, v} -> {k, v.points} end) ==
               Map.new(r2.scored, fn {k, v} -> {k, v.points} end)
    end
  end

  describe "recalculate/5 - fixed-point termination on an oscillating case" do
    test "a drawn game between two otherwise-tied players can oscillate forever; the iteration cap still returns" do
      a = player(1, "A", 2000)
      b = player(2, "B", 1800)
      c = player(3, "C", 1600)
      d = player(4, "D", 1400)

      # A beats B (decisive); C and D draw. Whichever of C/D is ranked
      # higher scores *less* than the one ranked lower (they each earn
      # half of the OTHER's current value), so re-ranking keeps swapping
      # C and D every single iteration - a genuine, unbounded oscillation
      # given this system's literal rules.
      games = [
        %{round: 1, white_id: a.id, black_id: b.id, result: "1-0"},
        %{round: 1, white_id: c.id, black_id: d.id, result: "1/2-1/2"}
      ]

      result = Keizer.recalculate([a, b, c, d], games, [], nil, 1)

      # Returns promptly (this test would time out on an infinite loop) at
      # the iteration cap rather than converging.
      assert result.iterations == 20
      assert Enum.sort(Enum.map(result.order, & &1.id)) == Enum.sort([a.id, b.id, c.id, d.id])
      # A is undisputedly first regardless of which oscillation phase we
      # landed on when the cap hit.
      assert hd(result.order).id == a.id
    end
  end

  ## ---------- pairing: cascade, forbidden pairs, repeats, byes ----------

  describe "match_round/3 - no-repeat with cascade backtracking" do
    test "backtracks past a dead end caused by a forbidden pair further down the list" do
      a = player(1, "A", 2000)
      b = player(2, "B", 1900)
      c = player(3, "C", 1800)
      d = player(4, "D", 1700)

      # No games played yet, but C-D is forbidden. Pairing A with B (the
      # naive nearest choice) strands C and D together with no valid
      # option - the matcher must backtrack and try A-C instead, freeing
      # up B-D.
      forbidden = MapSet.new([Keizer.pair_key(c.id, d.id)])

      assert {:ok, pairs, nil} = Keizer.match_round([a, b, c, d], %{}, forbidden)
      pair_sets = Enum.map(pairs, fn {x, y} -> MapSet.new([x.id, y.id]) end)

      assert MapSet.new([a.id, c.id]) in pair_sets
      assert MapSet.new([b.id, d.id]) in pair_sets
      refute MapSet.new([c.id, d.id]) in pair_sets
    end

    test "prefers the nearest never-played opponent when no backtracking is needed" do
      a = player(1, "A", 2000)
      b = player(2, "B", 1900)
      c = player(3, "C", 1800)
      d = player(4, "D", 1700)

      # A already played B - must skip to C.
      history = %{Keizer.pair_key(a.id, b.id) => 1}

      assert {:ok, pairs, nil} = Keizer.match_round([a, b, c, d], history, MapSet.new())
      pair_sets = Enum.map(pairs, fn {x, y} -> MapSet.new([x.id, y.id]) end)

      assert MapSet.new([a.id, c.id]) in pair_sets
      assert MapSet.new([b.id, d.id]) in pair_sets
    end
  end

  describe "match_round/3 - forbidden pairing is never paired" do
    test "a simple forbidden pair is skipped for the next nearest player" do
      a = player(1, "A", 2000)
      b = player(2, "B", 1900)
      c = player(3, "C", 1800)

      forbidden = MapSet.new([Keizer.pair_key(a.id, b.id)])

      assert {:ok, pairs, bye} = Keizer.match_round([a, b, c], %{}, forbidden)
      assert bye.id == b.id or bye.id == c.id

      refute Enum.any?(pairs, fn {x, y} ->
               MapSet.new([x.id, y.id]) == MapSet.new([a.id, b.id])
             end)
    end
  end

  describe "match_round/3 - forced repeats prefer the pair repeated longest ago" do
    test "when every option is a repeat, the oldest repeat is chosen" do
      a = player(1, "A", 2000)
      b = player(2, "B", 1900)
      c = player(3, "C", 1800)
      d = player(4, "D", 1700)

      # A has played everyone; C is the oldest encounter (round 1), so a
      # forced repeat should pick A-C over A-B (round 3) or A-D (round 2).
      history = %{
        Keizer.pair_key(a.id, b.id) => 3,
        Keizer.pair_key(a.id, c.id) => 1,
        Keizer.pair_key(a.id, d.id) => 2
      }

      assert {:ok, pairs, nil} = Keizer.match_round([a, b, c, d], history, MapSet.new())
      assert {^a, ^c} = Enum.find(pairs, fn {x, _y} -> x.id == a.id end)
    end
  end

  describe "match_round/3 - odd count gives the bye to the bottom-ranked player" do
    test "5 players: the lowest-ranked unpaired player gets the bye" do
      players =
        for {n, i} <- Enum.with_index([2000, 1900, 1800, 1700, 1600], 1),
            do: player(i, "P#{i}", n)

      assert {:ok, pairs, bye} = Keizer.match_round(players, %{}, MapSet.new())
      assert length(pairs) == 2
      assert bye.id == 5
    end
  end

  describe "assign_colours/3 - colour rule" do
    test "the player with fewer games as White gets White" do
      a = player(1, "A", 2000)
      b = player(2, "B", 1900)
      order = [a, b]
      white_counts = %{a.id => 2, b.id => 0}

      assert Keizer.assign_colours([{a, b}], order, white_counts) == [{b, a}]
    end

    test "tied on White games, the lower-ranked player gets White" do
      a = player(1, "A", 2000)
      b = player(2, "B", 1900)
      order = [a, b]

      assert Keizer.assign_colours([{a, b}], order, %{}) == [{b, a}]
    end

    test "colour is never a reason to skip a pairing - always returns one entry per pair" do
      a = player(1, "A", 2000)
      b = player(2, "B", 1900)
      c = player(3, "C", 1800)
      d = player(4, "D", 1700)

      pairs = [{a, b}, {c, d}]
      assert length(Keizer.assign_colours(pairs, [a, b, c, d], %{})) == 2
    end
  end

  ## ---------- end-to-end: Pairing.pair_next_round + result entry + Keizer.standings ----------

  describe "end-to-end via Pairing.pair_next_round/1 and Keizer.standings/1" do
    setup do
      tournament =
        Repo.insert!(%Tournament{
          name: "Keizer Club Night",
          type: "swiss",
          pairing_system: "keizer",
          rounds_count: 3
        })

      a = insert_player(tournament, "Alice", fide_rating: 2000)
      b = insert_player(tournament, "Bob", fide_rating: 1900)
      c = insert_player(tournament, "Carol", fide_rating: 1800)
      d = insert_player(tournament, "Dave", fide_rating: 1700)

      {:ok, tournament: tournament, a: a, b: b, c: c, d: d}
    end

    test "dispatches through PairingsEngine.Pairing, pairs, accepts results, and standings reflects them",
         %{tournament: tournament, a: a, b: b, c: c, d: d} do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))

      assert {:ok, round1} = Pairing.pair_next_round(tournament)
      tid = tournament.id
      assert_receive {:tournament_changed, ^tid, :rounds}

      round1 = Repo.preload(round1, :pairings)
      assert length(round1.pairings) == 2

      # Enter round 1 results.
      Enum.each(round1.pairings, fn pairing ->
        {:ok, _} = Tournaments.update_pairing_result(pairing, "1-0")
      end)

      assert {:ok, round2} = Pairing.pair_next_round(tournament)
      round2 = Repo.preload(round2, :pairings)
      assert length(round2.pairings) == 2

      # No pair from round 1 repeats in round 2.
      round1_pairs =
        MapSet.new(round1.pairings, &MapSet.new([&1.white_player_id, &1.black_player_id]))

      refute Enum.any?(round2.pairings, fn p ->
               MapSet.new([p.white_player_id, p.black_player_id]) in round1_pairs
             end)

      entries = Keizer.standings(tournament)
      assert length(entries) == 4
      assert Enum.map(entries, & &1.rank) == [1, 2, 3, 4]
      # Ranked strictly by descending Keizer points.
      points = Enum.map(entries, & &1.points)
      assert points == Enum.sort(points, :desc)

      player_ids = MapSet.new([a.id, b.id, c.id, d.id])
      assert MapSet.new(entries, & &1.player.id) == player_ids
    end

    test "the first pairing freezes pairing_number (highest rating first, frozen thereafter)",
         %{tournament: tournament, a: a, b: b, c: c, d: d} do
      refute a.pairing_number
      refute b.pairing_number
      refute c.pairing_number
      refute d.pairing_number

      assert {:ok, _round1} = Pairing.pair_next_round(tournament)

      reloaded = fn p -> Repo.get!(Player, p.id) end

      # Alice(2000) > Bob(1900) > Carol(1800) > Dave(1700) - same
      # highest-rating-first numbering the Swiss path uses.
      assert reloaded.(a).pairing_number == 1
      assert reloaded.(b).pairing_number == 2
      assert reloaded.(c).pairing_number == 3
      assert reloaded.(d).pairing_number == 4

      # Pairing round 2 doesn't renumber anyone - the numbers stay frozen.
      Enum.each(
        Repo.preload(Tournaments.get_round(tournament.id, 1), :pairings).pairings,
        fn pairing ->
          {:ok, _} = Tournaments.update_pairing_result(pairing, "1-0")
        end
      )

      assert {:ok, _round2} = Pairing.pair_next_round(tournament)
      assert reloaded.(a).pairing_number == 1
      assert reloaded.(d).pairing_number == 4
    end

    test "a round-specific absence excludes the player from pairing and records a requested-zero bye",
         %{tournament: tournament, d: d} do
      {:ok, d} = Tournaments.update_player(d, %{absent_rounds: "1"})

      assert {:ok, round} = Pairing.pair_next_round(tournament)
      round = Repo.preload(round, :pairings)

      paired_ids =
        round.pairings
        |> Enum.flat_map(&[&1.white_player_id, &1.black_player_id])
        |> Enum.reject(&is_nil/1)

      refute d.id in paired_ids

      byes =
        Repo.all(
          from b in "byes",
            where: b.tournament_id == ^tournament.id and b.player_id == ^d.id,
            select: b.type
        )

      assert byes == ["requested-zero"]

      # Still shows up in the Keizer standings despite not being paired.
      entries = Keizer.standings(tournament)
      assert Enum.any?(entries, &(&1.player.id == d.id))
    end

    test "a late entrant with start_round is excluded from pairing until it's reached, then included",
         %{tournament: tournament} do
      late = insert_player(tournament, "Eve", fide_rating: 1600, start_round: 2)

      assert {:ok, round1} = Pairing.pair_next_round(tournament)
      round1 = Repo.preload(round1, :pairings)

      paired_ids_r1 =
        round1.pairings
        |> Enum.flat_map(&[&1.white_player_id, &1.black_player_id])
        |> Enum.reject(&is_nil/1)

      refute late.id in paired_ids_r1

      # No "byes" row for the late entrant either - score_round/5's
      # :not_joined branch needs none (unlike an excused absence).
      byes_r1 =
        Repo.all(
          from b in "byes",
            where: b.tournament_id == ^tournament.id and b.player_id == ^late.id,
            select: b.type
        )

      assert byes_r1 == []

      Enum.each(round1.pairings, fn pairing ->
        {:ok, _} = Tournaments.update_pairing_result(pairing, "1-0")
      end)

      assert {:ok, round2} = Pairing.pair_next_round(tournament)
      round2 = Repo.preload(round2, :pairings)

      paired_ids_r2 =
        round2.pairings
        |> Enum.flat_map(&[&1.white_player_id, &1.black_player_id])
        |> Enum.reject(&is_nil/1)

      assert late.id in paired_ids_r2

      entries = Keizer.standings(tournament)
      assert Enum.any?(entries, &(&1.player.id == late.id))
    end

    test "pair_next_round/1 rejects pairing once all rounds are used up", %{
      tournament: tournament
    } do
      {:ok, r1} = Pairing.pair_next_round(tournament)

      Enum.each(
        Repo.preload(r1, :pairings).pairings,
        &Tournaments.update_pairing_result(&1, "1-0")
      )

      {:ok, r2} = Pairing.pair_next_round(tournament)

      Enum.each(
        Repo.preload(r2, :pairings).pairings,
        &Tournaments.update_pairing_result(&1, "1-0")
      )

      {:ok, r3} = Pairing.pair_next_round(tournament)

      Enum.each(
        Repo.preload(r3, :pairings).pairings,
        &Tournaments.update_pairing_result(&1, "1-0")
      )

      assert {:error, _reason} = Pairing.pair_next_round(tournament)
    end
  end

  describe "club/federation exclusions (PairingsEngine.Exclusions) respected by Keizer" do
    test "clubmates are never paired together under an \"all\" club exclusion rule" do
      tournament =
        Repo.insert!(%Tournament{
          name: "Keizer Club Night",
          type: "swiss",
          pairing_system: "keizer",
          rounds_count: 1,
          club_exclusion: "all"
        })

      # Alice/Bob are ranked 1st/2nd (highest ratings) and share a club -
      # without the exclusion rule they'd be paired together round 1.
      a = insert_player(tournament, "Alice", fide_rating: 2000, club: "Chess Club")
      b = insert_player(tournament, "Bob", fide_rating: 1900, club: "Chess Club")
      c = insert_player(tournament, "Carol", fide_rating: 1800)
      d = insert_player(tournament, "Dave", fide_rating: 1700)

      assert {:ok, round} = Pairing.pair_next_round(tournament)
      round = Repo.preload(round, :pairings)

      refute Enum.any?(round.pairings, fn p ->
               MapSet.new([p.white_player_id, p.black_player_id]) == MapSet.new([a.id, b.id])
             end)

      paired_ids =
        round.pairings
        |> Enum.flat_map(&[&1.white_player_id, &1.black_player_id])
        |> Enum.reject(&is_nil/1)

      assert MapSet.new(paired_ids) == MapSet.new([a.id, b.id, c.id, d.id])
    end
  end
end
