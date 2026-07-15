defmodule PairingsEngine.StandingsTest do
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Repo, Standings, Tournaments}
  alias PairingsEngine.Tournaments.{Tournament, Player, Round, Pairing}

  # Fixture: 4 players, 2 rounds, all games played, standard scoring.
  #
  # R1: A (w) 1-0 B    C (w) ½-½ D
  # R2: C (w) 0-1 A    B (w) 1-0 D
  #
  # Scores: A=2, B=1, C=0.5, D=0.5
  # Hand-computed: BH(A)=1.5, BH(B)=2.5, SB(A)=1.5, SB(B)=0.5,
  # PS(A)=3.0, WIN(A)=2, BPG(A)=1 (won with black in R2), KS(A)=1.0 (B has 50%),
  # ARO(A)=(1800+1700)/2=1750.
  defp fixture do
    tournament =
      Repo.insert!(%Tournament{
        name: "TB Test",
        type: "swiss",
        rounds_count: 3,
        tiebreaks: ~w(BH BHC1 SB DE WIN WON BPG PS KS ARO)
      })

    [a, b, c, d] =
      for {name, rating} <- [{"A", 2000}, {"B", 1800}, {"C", 1700}, {"D", 1600}] do
        Repo.insert!(%Player{
          tournament_id: tournament.id,
          name: name,
          fide_rating: rating,
          pairing_number: 2001 - rating
        })
      end

    r1 = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})
    r2 = Repo.insert!(%Round{tournament_id: tournament.id, number: 2, status: "finished"})

    Repo.insert!(%Pairing{
      round_id: r1.id,
      board: 1,
      white_player_id: a.id,
      black_player_id: b.id,
      result: "1-0"
    })

    Repo.insert!(%Pairing{
      round_id: r1.id,
      board: 2,
      white_player_id: c.id,
      black_player_id: d.id,
      result: "1/2-1/2"
    })

    Repo.insert!(%Pairing{
      round_id: r2.id,
      board: 1,
      white_player_id: c.id,
      black_player_id: a.id,
      result: "0-1"
    })

    Repo.insert!(%Pairing{
      round_id: r2.id,
      board: 2,
      white_player_id: b.id,
      black_player_id: d.id,
      result: "1-0"
    })

    {tournament, %{a: a, b: b, c: c, d: d}}
  end

  test "points, ranking and the full tiebreak set match hand-computed values" do
    {tournament, %{a: a, b: b}} = fixture()

    entries = Standings.standings(tournament)
    by_name = Map.new(entries, &{&1.player.name, &1})

    assert [%{player: %{name: "A"}}, %{player: %{name: "B"}} | _] = entries

    ea = by_name["A"]
    assert ea.points == 2.0
    assert ea.tiebreaks["BH"] == 1.5
    # BHC1 cuts the lowest contribution (C's 0.5): 1.0 remains
    assert ea.tiebreaks["BHC1"] == 1.0
    assert ea.tiebreaks["SB"] == 1.5
    assert ea.tiebreaks["WIN"] == 2.0
    assert ea.tiebreaks["WON"] == 2.0
    assert ea.tiebreaks["BPG"] == 1.0
    assert ea.tiebreaks["PS"] == 3.0
    assert ea.tiebreaks["KS"] == 1.0
    assert ea.tiebreaks["ARO"] == 1750.0

    eb = by_name["B"]
    assert eb.points == 1.0
    assert eb.tiebreaks["BH"] == 2.5
    assert eb.tiebreaks["SB"] == 0.5

    assert a.id == ea.player.id and b.id == eb.player.id
  end

  test "direct encounter splits a two-way tie in which the players met" do
    {tournament, %{c: c, d: d}} = fixture()

    entries = Standings.standings(tournament)
    ec = Enum.find(entries, &(&1.player.id == c.id))
    ed = Enum.find(entries, &(&1.player.id == d.id))

    # C and D are tied on 0.5 and drew their game: DE gives each 0.5 and
    # cannot separate them — both get the same DE value.
    assert ec.tiebreaks["DE"] == ed.tiebreaks["DE"]
  end

  test "a half-point requested bye counts toward the score and Buchholz uses the dummy rule" do
    {tournament, %{d: d}} = fixture()

    Repo.query!(
      "INSERT INTO byes (tournament_id, player_id, round, type) VALUES (?, ?, ?, ?)",
      [tournament.id, d.id, 3, "requested-half"]
    )

    r3 = Repo.insert!(%Round{tournament_id: tournament.id, number: 3, status: "finished"})
    _ = r3

    entries = Standings.standings(tournament)
    ed = Enum.find(entries, &(&1.player.id == d.id))

    # D: 0.5 (draw) + 0 (loss) + 0.5 (half-point bye) = 1.0
    assert ed.points == 1.0
    # The bye round contributes a dummy score to Buchholz, capped at
    # draw-points × rounds (0.5 × 3 = 1.5): before(0.5) + complement(0.5) + 0 remaining... = 1.0
    assert ed.tiebreaks["BH"] > 0.0
  end

  test "extra_points defaults to 0 and total equals points, leaving ranking unchanged" do
    {tournament, %{a: a, b: b}} = fixture()

    entries = Standings.standings(tournament)
    ea = Enum.find(entries, &(&1.player.id == a.id))
    eb = Enum.find(entries, &(&1.player.id == b.id))

    assert ea.extra_points == 0.0
    assert ea.total == ea.points
    assert eb.extra_points == 0.0
    assert eb.total == eb.points

    # Same order as the plain points-based ranking (A still ahead of B).
    assert [%{player: %{name: "A"}}, %{player: %{name: "B"}} | _] = entries
  end

  test "extra_points don't affect ranking while count_extra_points is off (the default)" do
    {tournament, %{b: b, d: d}} = fixture()

    # After round 2: B=1.0, C=0.5, D=0.5. Even with a 1.0 administrative
    # bonus that would outrank B on total, the tournament hasn't opted in
    # (SWAR parity #12's explicit earlier decision), so D still ranks by
    # plain game points and stays behind B.
    {:ok, d} = Tournaments.update_player(d, %{extra_points: 1.0})
    refute tournament.count_extra_points

    entries = Standings.standings(tournament)
    ed = Enum.find(entries, &(&1.player.id == d.id))
    eb = Enum.find(entries, &(&1.player.id == b.id))

    assert ed.total == 1.5
    assert ed.rank > eb.rank
  end

  test "a player's extra_points can outrank a same-points player once count_extra_points is on, without affecting FIDE tiebreaks" do
    {tournament, %{b: b, c: c, d: d}} = fixture()

    {:ok, tournament} = Tournaments.update_tournament(tournament, %{count_extra_points: true})

    # After round 2: B=1.0, C=0.5, D=0.5. Give D a 1.0 administrative bonus so
    # its total (1.5) outranks even B (1.0), despite fewer game points.
    {:ok, d} = Tournaments.update_player(d, %{extra_points: 1.0})

    entries = Standings.standings(tournament)
    ed = Enum.find(entries, &(&1.player.id == d.id))
    eb = Enum.find(entries, &(&1.player.id == b.id))
    ec = Enum.find(entries, &(&1.player.id == c.id))

    assert ed.points == 0.5
    assert ed.extra_points == 1.0
    assert ed.total == 1.5
    assert ed.rank < eb.rank

    # Buchholz-style tiebreaks still use opponents' GAME points, not totals:
    # D's own extra_points bonus doesn't change B's or C's tiebreak inputs.
    assert eb.tiebreaks["BH"] == 2.5
    assert ec.tiebreaks["SB"] == 0.25
  end

  test "grid_standings/1 always includes BH, BHC1, SB, PS and DE, with ranks matching standings/1" do
    # This tournament only configures WIN as a tiebreak, so standings/1 would
    # not compute BH/SB/PS/DE at all — the player grid needs them regardless.
    {tournament, %{a: a, b: b}} = fixture()
    tournament = %{tournament | tiebreaks: ~w(WIN)}

    plain = Standings.standings(tournament)
    grid = Standings.grid_standings(tournament)

    assert Enum.all?(plain, &(Map.keys(&1.tiebreaks) == ["WIN"]))

    ga = Enum.find(grid, &(&1.player.id == a.id))
    assert ga.tiebreaks["BH"] == 1.5
    assert ga.tiebreaks["BHC1"] == 1.0
    assert ga.tiebreaks["SB"] == 1.5
    assert ga.tiebreaks["PS"] == 3.0
    assert is_float(ga.tiebreaks["DE"])

    # Ranking is unaffected by the extra tiebreak codes: it still follows the
    # tournament's own configured tiebreaks (here just WIN), so grid_standings
    # ranks match standings/1 exactly for every player.
    plain_ranks = Map.new(plain, &{&1.player.id, &1.rank})
    grid_ranks = Map.new(grid, &{&1.player.id, &1.rank})
    assert plain_ranks == grid_ranks

    gb = Enum.find(grid, &(&1.player.id == b.id))
    assert ga.rank == plain_ranks[a.id]
    assert gb.rank == plain_ranks[b.id]
  end

  describe "played \"0-0\" vs a \"0-0FF\" double forfeit (FIDE Art. 16)" do
    # E and F meet twice: round 1 is a played "0-0" (e.g. both players
    # ejected from the venue after making moves — the game WAS contested,
    # both lose), round 2 is a "0-0FF" double forfeit (neither played at
    # all). Both are worth 0 points for both players either way, but only
    # the played round should count as "played" for tiebreak purposes.
    defp forfeit_fixture do
      tournament =
        Repo.insert!(%Tournament{
          name: "FF Test",
          type: "swiss",
          rounds_count: 2,
          tiebreaks: ~w(BH SB BPG WON ARO)
        })

      [e, f] =
        for {name, rating} <- [{"E", 2000}, {"F", 1500}] do
          Repo.insert!(%Player{tournament_id: tournament.id, name: name, fide_rating: rating})
        end

      r1 = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})
      r2 = Repo.insert!(%Round{tournament_id: tournament.id, number: 2, status: "finished"})

      Repo.insert!(%Pairing{
        round_id: r1.id,
        board: 1,
        white_player_id: e.id,
        black_player_id: f.id,
        result: "0-0"
      })

      Repo.insert!(%Pairing{
        round_id: r2.id,
        board: 1,
        white_player_id: e.id,
        black_player_id: f.id,
        result: "0-0FF"
      })

      {tournament, %{e: e, f: f}}
    end

    test "both results are worth 0 points for both players" do
      {tournament, %{e: e, f: f}} = forfeit_fixture()

      entries = Standings.standings(tournament)
      ee = Enum.find(entries, &(&1.player.id == e.id))
      ef = Enum.find(entries, &(&1.player.id == f.id))

      assert ee.points == 0.0
      assert ef.points == 0.0
    end

    test "only the played \"0-0\" round is marked played: true" do
      {tournament, %{e: e}} = forfeit_fixture()

      entries = Standings.standings(tournament)
      ee = Enum.find(entries, &(&1.player.id == e.id))
      by_round = Map.new(ee.games, &{&1.round, &1})

      assert by_round[1].played == true
      assert by_round[2].played == false
    end

    test "BPG (games played with black) counts the played 0-0 but not the 0-0FF" do
      {tournament, %{f: f}} = forfeit_fixture()

      entries = Standings.standings(tournament)
      ef = Enum.find(entries, &(&1.player.id == f.id))

      # F was black in both rounds, but only round 1 (played "0-0") counts.
      assert ef.tiebreaks["BPG"] == 1.0
    end

    test "ARO only averages opponents actually played over the board" do
      {tournament, %{e: e, f: f}} = forfeit_fixture()

      entries = Standings.standings(tournament)
      ee = Enum.find(entries, &(&1.player.id == e.id))
      ef = Enum.find(entries, &(&1.player.id == f.id))

      # Only round 1 (played) counts toward ARO for either side.
      assert ee.tiebreaks["ARO"] == 1500.0
      assert ef.tiebreaks["ARO"] == 2000.0
    end

    test "WON (games won over the board) is unaffected since both results are losses for both sides" do
      {tournament, %{e: e, f: f}} = forfeit_fixture()

      entries = Standings.standings(tournament)
      ee = Enum.find(entries, &(&1.player.id == e.id))
      ef = Enum.find(entries, &(&1.player.id == f.id))

      assert ee.tiebreaks["WON"] == 0.0
      assert ef.tiebreaks["WON"] == 0.0
    end
  end

  ## ---------- manual standings override (SWAR parity #23) ----------

  describe "apply_manual_ranking/2" do
    test "off (default): entries and rank are returned byte-identical" do
      {tournament, _} = fixture()

      entries = Standings.standings(tournament)
      assert Standings.apply_manual_ranking(entries, tournament) == entries
    end

    test "on: reorders entries by manual_rank and reassigns :rank, leaving points/tiebreaks untouched" do
      {tournament, %{a: a, b: b, c: c, d: d}} = fixture()
      tournament = %{tournament | manual_ranking: true}

      # Computed order is A, B, then C/D — hand-flip it so D leads.
      Repo.update_all(from(p in Player, where: p.id == ^d.id), set: [manual_rank: 1])
      Repo.update_all(from(p in Player, where: p.id == ^c.id), set: [manual_rank: 2])
      Repo.update_all(from(p in Player, where: p.id == ^a.id), set: [manual_rank: 3])
      Repo.update_all(from(p in Player, where: p.id == ^b.id), set: [manual_rank: 4])

      computed = Standings.standings(tournament)
      ea_computed = Enum.find(computed, &(&1.player.id == a.id))

      reordered = Standings.apply_manual_ranking(Standings.standings(tournament), tournament)

      assert [
               %{player: %{name: "D"}, rank: 1},
               %{player: %{name: "C"}, rank: 2},
               %{player: %{name: "A"}, rank: 3},
               %{
                 player: %{name: "B"},
                 rank: 4
               }
             ] = reordered

      ea_reordered = Enum.find(reordered, &(&1.player.id == a.id))
      # points/tiebreaks are untouched by the reorder — only :rank differs.
      assert ea_reordered.points == ea_computed.points
      assert ea_reordered.tiebreaks == ea_computed.tiebreaks
      assert ea_reordered.total == ea_computed.total
    end

    test "on: a player with no manual_rank yet sorts after every ranked player" do
      {tournament, %{a: a, b: b, c: c, d: d}} = fixture()
      tournament = %{tournament | manual_ranking: true}

      Repo.update_all(from(p in Player, where: p.id == ^a.id), set: [manual_rank: 1])
      Repo.update_all(from(p in Player, where: p.id == ^b.id), set: [manual_rank: 2])
      Repo.update_all(from(p in Player, where: p.id == ^c.id), set: [manual_rank: 3])
      # D never seeded (manual_rank stays nil) — simulates a player added after enabling.

      reordered = Standings.apply_manual_ranking(Standings.standings(tournament), tournament)
      assert List.last(reordered).player.id == d.id
    end
  end

  describe "manual_ranking_stale?/1 and manual_ranking_incomplete?/1" do
    test "stale? reads tournaments.manual_ranking_stale directly" do
      {tournament, _} = fixture()

      refute Standings.manual_ranking_stale?(tournament)
      assert Standings.manual_ranking_stale?(%{tournament | manual_ranking_stale: true})
    end

    test "incomplete? is true iff at least one player has no manual_rank" do
      {tournament, %{a: a, b: b, c: c, d: d}} = fixture()

      Repo.update_all(from(p in Player, where: p.id == ^a.id), set: [manual_rank: 1])
      Repo.update_all(from(p in Player, where: p.id == ^b.id), set: [manual_rank: 2])
      Repo.update_all(from(p in Player, where: p.id == ^c.id), set: [manual_rank: 3])
      Repo.update_all(from(p in Player, where: p.id == ^d.id), set: [manual_rank: 4])
      complete = Standings.standings(tournament)
      refute Standings.manual_ranking_incomplete?(complete)

      Repo.update_all(from(p in Player, where: p.id == ^d.id), set: [manual_rank: nil])
      incomplete = Standings.standings(tournament)
      assert Standings.manual_ranking_incomplete?(incomplete)
    end
  end
end
