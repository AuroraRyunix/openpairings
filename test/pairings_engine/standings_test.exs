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
    # Article 16.4: the bye round's dummy opponent score is D's OWN score
    # (1.0), capped at draw-points × rounds (0.5 × 3 = 1.5) — the cap
    # doesn't bind here since 1.0 < 1.5. See the dedicated cap test below
    # for a case where it does.
    assert ed.tiebreaks["BH"] == 3.5
    assert ed.tiebreaks["BHC1"] == 2.5
    assert ed.tiebreaks["SB"] == 1.0
  end

  test "Article 16.4's cap applies when a high scorer's own score exceeds draw-points × rounds" do
    # A single player, 3 rounds: 2 real wins, then a half-point bye — own
    # score 2.5 comfortably exceeds the cap (draw 0.5 × 3 rounds = 1.5), so
    # the bye's dummy contribution must be capped at 1.5, not the raw 2.5.
    # This is exactly the real-world case that exposed the bug this test
    # (and the one above) locks in: a strong player's own bye was
    # previously computed via a "points before this round + complementary
    # result + draws for every remaining round" reconstruction found
    # nowhere in the regulation, instead of the FIDE Handbook 07 Art. 16.4
    # text: "The dummy's score for the tie-break calculation is the
    # participant's own score" (capped per 16.4.2 for a bye/absence).
    tournament =
      Repo.insert!(%Tournament{
        name: "Cap Test",
        type: "swiss",
        rounds_count: 3,
        tiebreaks: ~w(BH)
      })

    [strong, weak1, weak2] =
      for {name, rating} <- [{"Strong", 2200}, {"Weak1", 1500}, {"Weak2", 1400}] do
        Repo.insert!(%Player{tournament_id: tournament.id, name: name, fide_rating: rating})
      end

    r1 = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})
    r2 = Repo.insert!(%Round{tournament_id: tournament.id, number: 2, status: "finished"})
    r3 = Repo.insert!(%Round{tournament_id: tournament.id, number: 3, status: "finished"})

    Repo.insert!(%Pairing{
      round_id: r1.id,
      board: 1,
      white_player_id: strong.id,
      black_player_id: weak1.id,
      result: "1-0"
    })

    Repo.insert!(%Pairing{
      round_id: r2.id,
      board: 1,
      white_player_id: strong.id,
      black_player_id: weak2.id,
      result: "1-0"
    })

    # weak1 and weak2 meet in round 3 (a draw) so each has a game record IN
    # round 3 — otherwise `adjusted_score/3` would treat their otherwise-
    # missing final round as an implicit withdrawal and pad their
    # contribution with draw credit, muddying this test's only point:
    # confirming the CAP on Strong's own bye specifically.
    Repo.insert!(%Pairing{
      round_id: r3.id,
      board: 1,
      white_player_id: weak1.id,
      black_player_id: weak2.id,
      result: "1/2-1/2"
    })

    Repo.query!(
      "INSERT INTO byes (tournament_id, player_id, round, type) VALUES (?, ?, ?, ?)",
      [tournament.id, strong.id, 3, "requested-half"]
    )

    entries = Standings.standings(tournament)
    e = Enum.find(entries, &(&1.player.id == strong.id))

    # Own score before the cap would be 1.0 (win) + 1.0 (win) + 0.5 (bye) = 2.5.
    assert e.points == 2.5
    # Buchholz = weak1's score (0.5) + weak2's score (0.5) + the bye's dummy
    # contribution, capped at 1.5 (not the raw 2.5) = 2.5.
    assert e.tiebreaks["BH"] == 2.5
  end

  # bye_points/2 is pure — a bare %Tournament{} struct is enough, no DB.
  # (Module level, not inside the describe below: ExUnit forbids defining
  # functions inside a describe block.)
  defp scoring_tournament(overrides) do
    struct!(
      %Tournament{
        points_win: 2.0,
        points_draw: 1.0,
        points_loss: 0.0,
        bye_value: 2.0,
        presence_value: 1.0
      },
      overrides
    )
  end

  # Opp: R1 win over Me (1.0), R2 a plain "absent" byes-table row scoring
  # points_loss (abs_value unset) — trailing, so it's the case
  # `adjusted_score/3`'s voluntary-window logic can affect. Me's BH is just
  # Opp's adjusted score (Me's only game is R1 against Opp). Module level,
  # not inside the describe below: ExUnit forbids defining functions inside
  # a describe block.
  defp fixture_with_absent_opponent(absent_counts_as_vur) do
    tournament =
      Repo.insert!(%Tournament{
        name: "Absent VUR Flag Test",
        type: "swiss",
        rounds_count: 2,
        tiebreaks: ~w(BH),
        points_win: 1.0,
        points_draw: 0.5,
        points_loss: 0.0,
        absent_counts_as_vur: absent_counts_as_vur
      })

    [me, opp] =
      for name <- ["Me", "Opp"] do
        Repo.insert!(%Player{tournament_id: tournament.id, name: name})
      end

    r1 = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})
    Repo.insert!(%Round{tournament_id: tournament.id, number: 2, status: "finished"})

    Repo.insert!(%Pairing{
      round_id: r1.id,
      board: 1,
      white_player_id: opp.id,
      black_player_id: me.id,
      result: "1-0"
    })

    Repo.query!(
      "INSERT INTO byes (tournament_id, player_id, round, type) VALUES (?, ?, ?, ?)",
      [tournament.id, opp.id, 2, "absent"]
    )

    entries = Standings.standings(tournament)
    Enum.find(entries, &(&1.player.id == me.id))
  end

  describe "bye_points/2 and the presence_on_allocated_bye (SW321_PreBye) flag" do
    test "pairing-allocated pays bye_value alone when the flag is off (default)" do
      t = scoring_tournament(presence_on_allocated_bye: false)
      assert Standings.bye_points("pairing-allocated", t) == 2.0
    end

    test "pairing-allocated pays bye_value + presence_value when the flag is on" do
      t = scoring_tournament(presence_on_allocated_bye: true)
      assert Standings.bye_points("pairing-allocated", t) == 3.0
    end

    test "flag on with a nil presence_value is nil-safe and pays bye_value alone" do
      # Shouldn't occur from the importer (only 3-2-1 imports set the flag,
      # and those always set presence_value), but bye_points/2 must never
      # crash on the combination.
      t = scoring_tournament(presence_on_allocated_bye: true, presence_value: nil)
      assert Standings.bye_points("pairing-allocated", t) == 2.0
    end

    test "the flag never leaks into the other bye types" do
      t = scoring_tournament(presence_on_allocated_bye: true)
      assert Standings.bye_points("requested-half", t) == 1.0
      assert Standings.bye_points("requested-zero", t) == 1.0
      assert Standings.bye_points("absent", t) == 0.0
    end

    test "a real result: \"bye\" Pairing row scores bye_value + presence_value in standings when the flag is on" do
      # The pairing-allocated bye's actual scoring path is
      # pairing_records/3's "bye" branch (a real Pairing row with no black
      # player), which must route through the same bye_points/2 rule — this
      # is the standings-side half of the SW321_PreBye model.
      tournament =
        Repo.insert!(%Tournament{
          name: "PreBye Test",
          type: "swiss",
          rounds_count: 1,
          points_win: 2.0,
          points_draw: 1.0,
          points_loss: 0.0,
          bye_value: 2.0,
          presence_value: 1.0,
          presence_on_allocated_bye: true,
          tiebreaks: ~w(BH)
        })

      player =
        Repo.insert!(%Player{
          tournament_id: tournament.id,
          name: "Bye Recipient",
          pairing_number: 1
        })

      r1 = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})

      Repo.insert!(%Pairing{
        round_id: r1.id,
        board: 1,
        white_player_id: player.id,
        black_player_id: nil,
        result: "bye"
      })

      [entry] = Standings.standings(tournament)
      assert entry.player.id == player.id
      # SW321_Bye (2.0) + SW321_Pre (1.0) — presence points on top.
      assert entry.points == 3.0
    end
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

  describe "asymmetric \"1/2-0\"/\"0-1/2\" results (VCL.13 — an arbiter's disciplinary point adjustment)" do
    defp asymmetric_fixture(result) do
      tournament =
        Repo.insert!(%Tournament{name: "Asymmetric Test", type: "swiss", rounds_count: 1})

      [white, black] =
        for name <- ["White", "Black"] do
          Repo.insert!(%Player{tournament_id: tournament.id, name: name, fide_rating: 2000})
        end

      round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})

      Repo.insert!(%Pairing{
        round_id: round.id,
        board: 1,
        white_player_id: white.id,
        black_player_id: black.id,
        result: result
      })

      {tournament, %{white: white, black: black}}
    end

    test "\"1/2-0\" credits White the draw value and Black nothing" do
      {tournament, %{white: white, black: black}} = asymmetric_fixture("1/2-0")

      entries = Standings.standings(tournament)
      ew = Enum.find(entries, &(&1.player.id == white.id))
      eb = Enum.find(entries, &(&1.player.id == black.id))

      assert ew.points == 0.5
      assert eb.points == 0.0
    end

    test "\"0-1/2\" credits Black the draw value and White nothing" do
      {tournament, %{white: white, black: black}} = asymmetric_fixture("0-1/2")

      entries = Standings.standings(tournament)
      ew = Enum.find(entries, &(&1.player.id == white.id))
      eb = Enum.find(entries, &(&1.player.id == black.id))

      assert ew.points == 0.0
      assert eb.points == 0.5
    end

    test "counts as played, unlike a forfeit" do
      {tournament, %{white: white}} = asymmetric_fixture("1/2-0")

      entries = Standings.standings(tournament)
      ew = Enum.find(entries, &(&1.player.id == white.id))
      by_round = Map.new(ew.games, &{&1.round, &1})

      assert by_round[1].played == true
    end
  end

  describe "regression: withdrawn opponent's missing trailing rounds and DE grouping key" do
    # X's only real record is the round-1 loss to A; X gets no pairing/bye
    # row for rounds 2-4 (simulating a withdrawn/forfeited player, since
    # `active_players/1` stops generating any record for such a player).
    # B and C keep playing each other every round purely to drive
    # `rounds_played_count(by_id)` up to 4 — not a realistic Swiss schedule,
    # just a unit-level tiebreak fixture.
    test "BH counts a withdrawn opponent's missing trailing rounds as draws (Article 16.3)" do
      tournament =
        Repo.insert!(%Tournament{
          name: "Withdrawn Opponent Test",
          type: "swiss",
          rounds_count: 4,
          tiebreaks: ~w(BH),
          points_win: 1.0,
          points_draw: 0.5,
          points_loss: 0.0
        })

      [a, x, b, c] =
        for name <- ["A", "X", "B", "C"] do
          Repo.insert!(%Player{tournament_id: tournament.id, name: name})
        end

      rounds =
        for n <- 1..4,
            do: Repo.insert!(%Round{tournament_id: tournament.id, number: n, status: "finished"})

      [r1, r2, r3, r4] = rounds

      Repo.insert!(%Pairing{
        round_id: r1.id,
        board: 1,
        white_player_id: a.id,
        black_player_id: x.id,
        result: "1-0"
      })

      for r <- [r1, r2, r3, r4] do
        Repo.insert!(%Pairing{
          round_id: r.id,
          board: 2,
          white_player_id: b.id,
          black_player_id: c.id,
          result: "1/2-1/2"
        })
      end

      entries = Standings.standings(tournament)
      ea = Enum.find(entries, &(&1.player.id == a.id))

      # X: real round-1 loss (0.0) + missing rounds 2-4 (3 × 0.5 draw-value)
      # = 1.5. Without the fix this would be 0.0 (rounds 2-4 silently
      # contribute nothing since X has no game record for them at all).
      assert ea.tiebreaks["BH"] == 1.5
    end

    # Opp gets a real pairing-allocated bye (odd player count — a `Pairing`
    # row with result "bye", not a `byes`-table row) in the LAST round, so it
    # falls in `adjusted_score/3`'s trailing window. Art. 16.2.1/16.3: a
    # pairing-allocated bye is never voluntary and must always count at its
    # awarded value for an opponent's tiebreak purposes — never downgraded to
    # a draw just because it's trailing. Before the fix, `voluntary` didn't
    # check `pairing.result != "bye"`, so this bye's real value (2.0, per
    # `bye_value` below) was silently replaced with a draw's worth (0.5).
    test "BH counts a trailing pairing-allocated bye at its awarded value, not a draw (Article 16.2.1/16.3)" do
      tournament =
        Repo.insert!(%Tournament{
          name: "Pairing-Allocated Trailing Bye Test",
          type: "swiss",
          rounds_count: 2,
          tiebreaks: ~w(BH),
          points_win: 1.0,
          points_draw: 0.5,
          points_loss: 0.0,
          bye_value: 2.0
        })

      [me, opp] =
        for name <- ["Me", "Opp"] do
          Repo.insert!(%Player{tournament_id: tournament.id, name: name})
        end

      r1 = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})
      r2 = Repo.insert!(%Round{tournament_id: tournament.id, number: 2, status: "finished"})

      Repo.insert!(%Pairing{
        round_id: r1.id,
        board: 1,
        white_player_id: me.id,
        black_player_id: opp.id,
        result: "1-0"
      })

      Repo.insert!(%Pairing{
        round_id: r2.id,
        board: 1,
        white_player_id: opp.id,
        black_player_id: nil,
        result: "bye"
      })

      entries = Standings.standings(tournament)
      e = Enum.find(entries, &(&1.player.id == me.id))

      # Opp's adjusted score = 0.0 (round-1 loss) + 2.0 (pairing-allocated
      # bye, awarded value) = 2.0. Without the fix it would be 0.0 + 0.5
      # (draw substituted for the trailing bye) = 0.5.
      assert e.tiebreaks["BH"] == 2.0
    end

    test "DE groups players tied on the ranking key (total), not raw points, when count_extra_points is on" do
      tournament =
        Repo.insert!(%Tournament{
          name: "DE Ranking Key Test",
          type: "swiss",
          rounds_count: 1,
          tiebreaks: ~w(DE),
          count_extra_points: true
        })

      p = Repo.insert!(%Player{tournament_id: tournament.id, name: "P", extra_points: 0.5})
      q = Repo.insert!(%Player{tournament_id: tournament.id, name: "Q", extra_points: 1.5})

      r1 = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})

      Repo.insert!(%Pairing{
        round_id: r1.id,
        board: 1,
        white_player_id: p.id,
        black_player_id: q.id,
        result: "1-0"
      })

      entries = Standings.standings(tournament)
      ep = Enum.find(entries, &(&1.player.id == p.id))
      eq = Enum.find(entries, &(&1.player.id == q.id))

      # P.points = 1.0, P.total = 1.5; Q.points = 0.0, Q.total = 1.5 — tied on
      # `total` (the actual ranking key here) but not on raw `points`. Without
      # the fix (grouping by raw points) they'd land in singleton groups and
      # both get DE == 0.0 despite being genuinely tied and having played
      # each other.
      assert ep.tiebreaks["DE"] == 1.0
      assert eq.tiebreaks["DE"] == 0.0
    end
  end

  describe "Article 16.5.1 Cut-1 Exception: a VUR contribution is cut in preference to an ordinary one" do
    # X: R1 win over Opp, R2 a requested-half bye (X's own dummy_score = 1.0,
    # capped at points_draw * rounds_count = 0.5 * 2 = 1.0 by Art. 16.4 — own
    # total 1.0 win + 0.5 bye = 1.5, capped down to 1.0). Opp: R1 loss to X,
    # R2 a real loss to Filler (0.0) — an explicit R2 record so Opp's
    # adjusted score is their own real total (0.0), not padded by the
    # "missing trailing round counts as a draw" rule that would otherwise
    # apply if Opp had no round-2 record at all. Filler pads out rounds so
    # `rounds_played_count/1` and Filler's own bookkeeping don't skew Opp's
    # adjustment; not itself asserted on. Two BHC1 contributions for X:
    # [0.0 (real, Opp), 1.0 (VUR, X's own bye)].
    #
    # Without the exception, cutting the plain lowest removes Opp's 0.0,
    # leaving X's own generous bye (1.0) — BHC1 == 1.0. With Art. 16.5.1,
    # the VUR contribution (1.0) is cut in preference instead, leaving
    # Opp's real 0.0 in the sum — BHC1 == 0.0. Confirms the exception
    # activates even when the VUR contribution is NOT the naturally lowest
    # value; a self-referential bye must not get to hide behind Cut-1's
    # protection meant for genuine weak-opponent luck.
    test "BHC1 cuts the participant's own bye contribution, not the naturally-lowest real result" do
      tournament =
        Repo.insert!(%Tournament{
          name: "Cut-1 Exception Test",
          type: "swiss",
          rounds_count: 2,
          tiebreaks: ~w(BHC1),
          points_win: 1.0,
          points_draw: 0.5,
          points_loss: 0.0
        })

      [x, opp, filler] =
        for name <- ["X", "Opp", "Filler"] do
          Repo.insert!(%Player{tournament_id: tournament.id, name: name})
        end

      r1 = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})
      r2 = Repo.insert!(%Round{tournament_id: tournament.id, number: 2, status: "finished"})

      Repo.insert!(%Pairing{
        round_id: r1.id,
        board: 1,
        white_player_id: x.id,
        black_player_id: opp.id,
        result: "1-0"
      })

      Repo.insert!(%Pairing{
        round_id: r2.id,
        board: 1,
        white_player_id: filler.id,
        black_player_id: opp.id,
        result: "1-0"
      })

      Repo.query!(
        "INSERT INTO byes (tournament_id, player_id, round, type) VALUES (?, ?, ?, ?)",
        [tournament.id, x.id, 2, "requested-half"]
      )

      entries = Standings.standings(tournament)
      ex = Enum.find(entries, &(&1.player.id == x.id))

      assert ex.tiebreaks["BHC1"] == 0.0
    end
  end

  describe "Tournament.absent_counts_as_vur — opt-in only, off by default (FIDE has no 'absent' concept)" do
    test "off (default): a trailing absence counts at its award value, not upgraded to a draw" do
      em = fixture_with_absent_opponent(false)
      # Opp's adjusted score = 1.0 (R1 win) + 0.0 (R2 absence, points_loss,
      # not treated as voluntary so it stays at its raw award value).
      assert em.tiebreaks["BH"] == 1.0
    end

    test "on: a trailing absence is downgraded to a draw, same as a requested bye" do
      em = fixture_with_absent_opponent(true)
      # Opp's adjusted score = 1.0 (R1 win) + 0.5 (R2 absence now inside
      # the trailing-voluntary window, counted as a draw per Art. 16.3).
      assert em.tiebreaks["BH"] == 1.5
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

  # Regression coverage for a real bug report: an arbiter entered exactly
  # one result — a fixed-board pairing (real board 1, displayed as "1001",
  # see PairingsEngine.PairingDisplay) — and worried the win had been
  # credited to the wrong player, since a *different*, unrelated player's
  # row also showed 1.0 points. That second player turned out to have a
  # full-point bye that round — a real, independent point, not
  # cross-contamination. This test locks in that a fixed-board result and
  # a same-round bye are scored completely independently: standings are
  # keyed by player_id end to end (PairingDisplay never touches
  # `pairing.board`, and Standings never reads `.board` at all), so a
  # fixed-board relabeling can't confuse which player's row a result
  # lands on.
  describe "a fixed-board result and a same-round bye don't cross-contaminate" do
    test "the fixed-board winner, loser, and the bye player each score exactly their own result" do
      tournament =
        Repo.insert!(%Tournament{
          name: "Fixed Board + Bye Test",
          type: "swiss",
          rounds_count: 1,
          tiebreaks: ~w(WIN)
        })

      [de_block, de_meyere, roersma, vandenhole] =
        for {name, rating} <- [
              {"De Block, Yordi", 1951},
              {"De Meyere, Dirk", 1590},
              {"Roersma, Melvin", nil},
              {"Vandenhole, Kobe", 2336}
            ] do
          Repo.insert!(%Player{tournament_id: tournament.id, name: name, fide_rating: rating})
        end

      # De Block is on a fixed (special) table — real board 1, displayed as
      # "1001" — paired against De Meyere, an ordinary player.
      Repo.update!(Ecto.Changeset.change(de_block, fixed_board: 1001))

      round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

      pairing =
        Repo.insert!(%Pairing{
          round_id: round.id,
          board: 1,
          white_player_id: de_block.id,
          black_player_id: de_meyere.id,
          result: ""
        })

      Repo.insert!(%Pairing{
        round_id: round.id,
        board: 2,
        white_player_id: vandenhole.id,
        black_player_id: nil,
        result: "bye"
      })

      Repo.query!(
        "INSERT INTO byes (tournament_id, player_id, round, type) VALUES (?, ?, ?, ?)",
        [tournament.id, roersma.id, 1, "pairing-allocated"]
      )

      # Same write path the Pairings page's inline result <select> and the
      # CSV bulk-import both use (see PairingsEngine.ResultsImport) —
      # "0-1": White (De Block) loses, Black (De Meyere) wins.
      {:ok, _} = Tournaments.update_pairing_result(pairing, "0-1")

      by_name = Standings.standings(tournament) |> Map.new(&{&1.player.name, &1})

      assert by_name["De Meyere, Dirk"].points == 1.0
      assert by_name["De Meyere, Dirk"].tiebreaks["WIN"] == 1.0

      assert by_name["De Block, Yordi"].points == 0.0
      assert by_name["De Block, Yordi"].tiebreaks["WIN"] == 0.0

      # Roersma's point comes entirely from their own bye — untouched by
      # the fixed-board result entered above.
      assert by_name["Roersma, Melvin"].points == 1.0
      assert by_name["Roersma, Melvin"].tiebreaks["WIN"] == 1.0

      # Vandenhole's bye (board 2) is likewise unaffected.
      assert by_name["Vandenhole, Kobe"].points == 1.0
    end
  end
end
