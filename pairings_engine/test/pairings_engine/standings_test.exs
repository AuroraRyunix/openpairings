defmodule PairingsEngine.StandingsTest do
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Repo, Standings}
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

    Repo.insert!(%Pairing{round_id: r1.id, board: 1, white_player_id: a.id, black_player_id: b.id, result: "1-0"})
    Repo.insert!(%Pairing{round_id: r1.id, board: 2, white_player_id: c.id, black_player_id: d.id, result: "1/2-1/2"})
    Repo.insert!(%Pairing{round_id: r2.id, board: 1, white_player_id: c.id, black_player_id: a.id, result: "0-1"})
    Repo.insert!(%Pairing{round_id: r2.id, board: 2, white_player_id: b.id, black_player_id: d.id, result: "1-0"})

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
end
