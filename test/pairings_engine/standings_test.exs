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

  describe "player_scores_before_round/2" do
    test "round 1 is everyone at 0 (nothing played yet, through_round: 0)" do
      {tournament, %{a: a, b: b, c: c, d: d}} = fixture()

      scores = Standings.player_scores_before_round(tournament, 1)

      assert scores == %{a.id => 0.0, b.id => 0.0, c.id => 0.0, d.id => 0.0}
    end

    test "round 2 reflects round 1's results, not round 2's own (already-entered) ones" do
      {tournament, %{a: a, b: b, c: c, d: d}} = fixture()

      scores = Standings.player_scores_before_round(tournament, 2)

      assert scores == %{a.id => 1.0, b.id => 0.0, c.id => 0.5, d.id => 0.5}
    end
  end

  test "direct encounter splits a two-way tie in which the players met" do
    {tournament, %{c: c, d: d}} = fixture()

    entries = Standings.standings(tournament)
    ec = Enum.find(entries, &(&1.player.id == c.id))
    ed = Enum.find(entries, &(&1.player.id == d.id))

    # C and D are tied on 0.5 and drew their game: DE gives each 0.5 and
    # cannot separate them - both get the same DE value.
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
    # (1.0), capped at draw-points × rounds (0.5 × 3 = 1.5) - the cap
    # doesn't bind here since 1.0 < 1.5. See the dedicated cap test below
    # for a case where it does.
    assert ed.tiebreaks["BH"] == 3.5
    assert ed.tiebreaks["BHC1"] == 2.5
    assert ed.tiebreaks["SB"] == 1.0
  end

  test "Article 16.4's cap applies when a high scorer's own score exceeds draw-points × rounds" do
    # A single player, 3 rounds: 2 real wins, then a half-point bye - own
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
    # round 3 - otherwise `adjusted_score/3` would treat their otherwise-
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

  # bye_points/2 is pure - a bare %Tournament{} struct is enough, no DB.
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
  # points_loss (abs_value unset) - trailing, so it's the case
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
      # player), which must route through the same bye_points/2 rule - this
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
      # SW321_Bye (2.0) + SW321_Pre (1.0) - presence points on top.
      assert entry.points == 3.0
    end

    test "WON counts games won over the board, not rounds worth as much as a win" do
      # Belgian 3-2-1: a draw pays points_draw 1.0 plus the presence point,
      # landing on exactly points_win 2.0. Article 7.2 asks for "the number
      # of games won over the board", so this player has none - the old
      # `points >= points_win` reading called the draw a win. Its neighbour
      # 7.1 (WIN) is defined in points, in those words, and must still count
      # the round.
      tournament =
        Repo.insert!(%Tournament{
          name: "3-2-1 WON",
          type: "swiss",
          rounds_count: 1,
          points_win: 2.0,
          points_draw: 1.0,
          points_loss: 0.0,
          presence_value: 1.0,
          tiebreaks: ~w(WIN WON)
        })

      [white, black] =
        for {name, nr} <- [{"Drawer", 1}, {"Other", 2}] do
          Repo.insert!(%Player{tournament_id: tournament.id, name: name, pairing_number: nr})
        end

      r1 = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})

      Repo.insert!(%Pairing{
        round_id: r1.id,
        board: 1,
        white_player_id: white.id,
        black_player_id: black.id,
        result: "1/2-1/2"
      })

      entry = Standings.standings(tournament) |> Enum.find(&(&1.player.id == white.id))

      assert entry.points == 2.0
      assert entry.tiebreaks["WIN"] == 1.0
      assert entry.tiebreaks["WON"] == 0.0
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
    # not compute BH/SB/PS/DE at all - the player grid needs them regardless.
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
    # ejected from the venue after making moves - the game WAS contested,
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

  describe "asymmetric \"1/2-0\"/\"0-1/2\" results (VCL.13 - an arbiter's disciplinary point adjustment)" do
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
    # `rounds_played_count(by_id)` up to 4 - not a realistic Swiss schedule,
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

    # Opp gets a real pairing-allocated bye (odd player count - a `Pairing`
    # row with result "bye", not a `byes`-table row) in the LAST round, so it
    # falls in `adjusted_score/3`'s trailing window. Art. 16.2.1/16.3: a
    # pairing-allocated bye is never voluntary and must always count at its
    # awarded value for an opponent's tiebreak purposes - never downgraded to
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

      # P.points = 1.0, P.total = 1.5; Q.points = 0.0, Q.total = 1.5 - tied on
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
    # capped at points_draw * rounds_count = 0.5 * 2 = 1.0 by Art. 16.4 - own
    # total 1.0 win + 0.5 bye = 1.5, capped down to 1.0). Opp: R1 loss to X,
    # R2 a real loss to Filler (0.0) - an explicit R2 record so Opp's
    # adjusted score is their own real total (0.0), not padded by the
    # "missing trailing round counts as a draw" rule that would otherwise
    # apply if Opp had no round-2 record at all. Filler pads out rounds so
    # `rounds_played_count/1` and Filler's own bookkeeping don't skew Opp's
    # adjustment; not itself asserted on. Two BHC1 contributions for X:
    # [0.0 (real, Opp), 1.0 (VUR, X's own bye)].
    #
    # Without the exception, cutting the plain lowest removes Opp's 0.0,
    # leaving X's own generous bye (1.0) - BHC1 == 1.0. With Art. 16.5.1,
    # the VUR contribution (1.0) is cut in preference instead, leaving
    # Opp's real 0.0 in the sum - BHC1 == 0.0. Confirms the exception
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

  describe "progressive score across a withdrawal (Art. 7.5 with 16.1.1)" do
    test "the series runs to the end of the event, not to the last record" do
      # A player who withdraws has no record for the rounds after they left -
      # absent_players/1 requires status == active and forfeit == false, so no
      # byes row is written - while build_standings/3 still ranks them. The
      # fold over entry.games therefore stopped early and understated their PS
      # by (rounds since leaving) x (frozen score).
      #
      # C.07 Art. 16.1.1 settles what those rounds are worth: "any round after
      # a participant withdraws is a zero-point-bye", so they exist and add
      # nothing - the running total carries forward.
      tournament =
        Repo.insert!(%Tournament{
          name: "Withdrawal",
          type: "swiss",
          rounds_count: 3,
          tiebreaks: ["PS"]
        })

      {:ok, quitter} = Tournaments.create_player(tournament.id, %{"name" => "Quitter"})
      {:ok, stayer} = Tournaments.create_player(tournament.id, %{"name" => "Stayer"})
      {:ok, third} = Tournaments.create_player(tournament.id, %{"name" => "Third"})
      {:ok, fourth} = Tournaments.create_player(tournament.id, %{"name" => "Fourth"})

      # Round 1: Quitter wins, and then leaves the event.
      r1 = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})

      Repo.insert!(%PairingsEngine.Tournaments.Pairing{
        round_id: r1.id,
        board: 1,
        white_player_id: quitter.id,
        black_player_id: stayer.id,
        result: "1-0"
      })

      Repo.insert!(%PairingsEngine.Tournaments.Pairing{
        round_id: r1.id,
        board: 2,
        white_player_id: third.id,
        black_player_id: fourth.id,
        result: "1-0"
      })

      # Rounds 2 and 3 happen without them.
      for n <- 2..3 do
        r = Repo.insert!(%Round{tournament_id: tournament.id, number: n, status: "finished"})

        Repo.insert!(%PairingsEngine.Tournaments.Pairing{
          round_id: r.id,
          board: 1,
          white_player_id: stayer.id,
          black_player_id: third.id,
          result: "1-0"
        })
      end

      {:ok, _} =
        quitter |> Ecto.Changeset.change(status: "withdrawn") |> Repo.update()

      entry =
        tournament
        |> Standings.standings()
        |> Enum.find(&(&1.player.id == quitter.id))

      # One point after round 1, and still one after rounds 2 and 3 - the
      # zero-point byes leave the running total where it was.
      assert entry.tiebreaks["PS"] == 3.0,
             "PS stopped at the last record instead of running to round 3"
    end
  end

  describe "played_result?/1 and the case it mirrors" do
    test "every code it calls played really is played in pairing_records/4" do
      # The two live in one module and must be edited together: the list is
      # what SwarExport now asks, and the case is what the standings use.
      # This drives each code through the real path and checks the answers
      # agree, so the list cannot quietly fall behind the case the way
      # SwarExport's private four-code copy did.
      for result <- ~w(1-0 1/2-1/2 0-1 1/2-0 0-1/2 0-0 1-0U 0-1U 1/2-1/2U) do
        assert Standings.played_result?(result), "#{result} should count as played"
      end

      for result <- ~w(1-0FF 0-1FF 0-0FF +-- --+) do
        refute Standings.played_result?(result),
               "#{result} is a forfeit - unplayed under FIDE Art. 16"
      end
    end

    test "it agrees with what pairing_records/4 actually marks" do
      # Not a restatement of the list - a comparison against the case.
      for result <- ~w(1-0 1/2-1/2 0-1 1/2-0 0-1/2 0-0 1-0U 0-1U 1/2-1/2U 1-0FF 0-1FF 0-0FF) do
        tournament =
          Repo.insert!(%Tournament{
            name: "P #{result}",
            type: "swiss",
            rounds_count: 1,
            tiebreaks: []
          })

        {:ok, w} = Tournaments.create_player(tournament.id, %{"name" => "W"})
        {:ok, b} = Tournaments.create_player(tournament.id, %{"name" => "B"})

        round =
          Repo.insert!(%PairingsEngine.Tournaments.Round{
            tournament_id: tournament.id,
            number: 1,
            status: "finished"
          })

        Repo.insert!(%PairingsEngine.Tournaments.Pairing{
          round_id: round.id,
          board: 1,
          white_player_id: w.id,
          black_player_id: b.id,
          result: result
        })

        entry = tournament |> Standings.standings() |> Enum.find(&(&1.player.id == w.id))
        [record] = entry.games

        assert record.played == Standings.played_result?(result),
               "#{result}: the case says played=#{record.played}, the list says " <>
                 "#{Standings.played_result?(result)}"
      end
    end
  end

  describe "Tournament.absent_counts_as_vur - on by default, opt OUT for the strict reading" do
    test "off: a trailing absence counts at its award value, not upgraded to a draw" do
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

    test "and ON is what a tournament nobody configured actually gets" do
      # Both tests above pass the flag explicitly, so neither of them would
      # have noticed the default moving - and it did move, while the field's
      # own comment went on saying "never on by default" for a while. Assert
      # the value an arbiter who touches nothing receives.
      assert %Tournament{}.absent_counts_as_vur == true

      tournament = Repo.insert!(%Tournament{name: "Default", type: "swiss", rounds_count: 2})
      assert tournament.absent_counts_as_vur == true
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

      # Computed order is A, B, then C/D - hand-flip it so D leads.
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
      # points/tiebreaks are untouched by the reorder - only :rank differs.
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
      # D never seeded (manual_rank stays nil) - simulates a player added after enabling.

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
  # one result - a fixed-board pairing (real board 1, displayed as "1001",
  # see PairingsEngine.PairingDisplay) - and worried the win had been
  # credited to the wrong player, since a *different*, unrelated player's
  # row also showed 1.0 points. That second player turned out to have a
  # full-point bye that round - a real, independent point, not
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

      # De Block is on a fixed (special) table - real board 1, displayed as
      # "1001" - paired against De Meyere, an ordinary player.
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
      # CSV bulk-import both use (see PairingsEngine.ResultsImport) -
      # "0-1": White (De Block) loses, Black (De Meyere) wins.
      {:ok, _} = Tournaments.update_pairing_result(pairing, "0-1")

      by_name = Standings.standings(tournament) |> Map.new(&{&1.player.name, &1})

      assert by_name["De Meyere, Dirk"].points == 1.0
      assert by_name["De Meyere, Dirk"].tiebreaks["WIN"] == 1.0

      assert by_name["De Block, Yordi"].points == 0.0
      assert by_name["De Block, Yordi"].tiebreaks["WIN"] == 0.0

      # Roersma's point comes entirely from their own bye - untouched by
      # the fixed-board result entered above.
      assert by_name["Roersma, Melvin"].points == 1.0
      assert by_name["Roersma, Melvin"].tiebreaks["WIN"] == 1.0

      # Vandenhole's bye (board 2) is likewise unaffected.
      assert by_name["Vandenhole, Kobe"].points == 1.0
    end
  end

  describe "SWAR 3-2-1 presence points on played rounds" do
    # The "1" in 3-2-1. SWAR's scheme is Win 2 / Draw 1 / Loss 0 with a
    # presence point on top, totalling 3 / 2 / 1 -- and it pays that point
    # per ROUND ATTENDED, in a separate accumulator added to the result
    # points (GetPresentPtsUntilRound, Classement.cpp:137; the sum at
    # Classement.cpp:1425). Scoring the result value alone turns a 3-2-1
    # tournament into a 2-1-0 one.
    #
    # Every 3-2-1 test before this one exercised only BYES, which is how a
    # whole scoring mode shipped without a played round ever being checked.
    defp swiss321_tournament do
      Repo.insert!(%Tournament{
        name: "321",
        type: "swiss",
        rounds_count: 2,
        tiebreaks: ["BH"],
        points_win: 2.0,
        points_draw: 1.0,
        points_loss: 0.0,
        presence_value: 1.0
      })
    end

    defp plain_tournament do
      Repo.insert!(%Tournament{
        name: "Normal",
        type: "swiss",
        rounds_count: 1,
        tiebreaks: ["BH"],
        points_win: 1.0,
        points_draw: 0.5,
        points_loss: 0.0
      })
    end

    defp two_players(t) do
      for {name, n} <- [{"A", 1}, {"B", 2}] do
        Repo.insert!(%Player{tournament_id: t.id, name: name, pairing_number: n})
      end
    end

    defp play(t, round_number, white, black, result) do
      r = Repo.insert!(%Round{tournament_id: t.id, number: round_number, status: "finished"})

      Repo.insert!(%Pairing{
        round_id: r.id,
        board: 1,
        white_player_id: white.id,
        black_player_id: black.id,
        result: result
      })
    end

    defp score(t, player) do
      t |> Standings.standings() |> Enum.find(&(&1.player.id == player.id)) |> Map.get(:points)
    end

    test "a played win scores 3, a loss scores 1 - not 2 and 0" do
      t = swiss321_tournament()
      [a, b] = two_players(t)
      play(t, 1, a, b, "1-0")

      assert score(t, a) == 3.0
      assert score(t, b) == 1.0
    end

    test "a played draw scores 2 for both" do
      t = swiss321_tournament()
      [a, b] = two_players(t)
      play(t, 1, a, b, "1/2-1/2")

      assert score(t, a) == 2.0
      assert score(t, b) == 2.0
    end

    test "presence accumulates per round, so missing one costs a point" do
      t = swiss321_tournament()
      [a, b] = two_players(t)
      play(t, 1, a, b, "1-0")
      play(t, 2, a, b, "0-1")

      # One win and one loss each, so the RESULT points tie at 2.0 apiece.
      # Both attended both rounds, so both collect two presence points.
      assert score(t, a) == 4.0
      assert score(t, b) == 4.0
    end

    # RESULTATS_WIN is `WIN | WIN_BYE | WIN_FF`, and LOST_FF/DRAW_FF are in
    # none of the three sets the presence condition tests - so a forfeit
    # pays the winner only. The player who did not turn up does not collect
    # a point for turning up.
    test "a forfeit pays presence to the winner only" do
      t = swiss321_tournament()
      [a, b] = two_players(t)
      play(t, 1, a, b, "1-0FF")

      assert score(t, a) == 3.0
      assert score(t, b) == 0.0
    end

    test "a double forfeit pays neither" do
      t = swiss321_tournament()
      [a, b] = two_players(t)
      play(t, 1, a, b, "0-0FF")

      assert score(t, a) == 0.0
      assert score(t, b) == 0.0
    end

    # ZERO_ZERO is in RESULTATS_SPECIAUX, so a played 0-0 pays both.
    test "a played 0-0 pays presence to both" do
      t = swiss321_tournament()
      [a, b] = two_players(t)
      play(t, 1, a, b, "0-0")

      assert score(t, a) == 1.0
      assert score(t, b) == 1.0
    end

    # presence_value is nil for every tournament that is not a 3-2-1
    # import, which is what keeps all of this inert everywhere else.
    test "an ordinary tournament is untouched" do
      t = plain_tournament()
      [a, b] = two_players(t)
      play(t, 1, a, b, "1-0")

      assert score(t, a) == 1.0
      assert score(t, b) == 0.0
    end
  end

  describe "a round still being played does not move anybody's tiebreaks" do
    # The defect this pins, in one sentence: an unreported pairing produces no
    # game record at all, so a round count taken from RECORD counts jumped the
    # instant the FIRST board of a round reported - and every player who had
    # not yet reported suddenly looked like they had missed a round.
    #
    # It was reachable in the most ordinary situation there is: a round in
    # progress, results coming in one board at a time, an arbiter watching the
    # standings on a projector. Every un-reported player's opponents gained a
    # phantom draw on Buchholz, BHC1, BHC2, MBH and SB, and Koya's 50%
    # threshold moved a full win, at the moment one result was typed in.
    #
    # Fixed by asking the ROUNDS how many of them are complete, rather than
    # asking the players how many records they hold. Those are different
    # quantities and the old code subtracted one from the other.
    #
    # SIX players, not four, and the assertions are about E and F. With four
    # players every remaining player's round-1 opponent is on the board being
    # reported, so their Buchholz moves for a completely legitimate reason -
    # an opponent scored a point - and the test cannot tell that apart from
    # the defect. E and F played only each other, and neither is in the game
    # that reports, so nothing about them may move at all.
    defp mid_round_fixture do
      t =
        Repo.insert!(%Tournament{
          name: "Mid-round",
          type: "swiss",
          rounds_count: 3,
          tiebreaks: ~w(BH BHC1 SB KS)
        })

      [a, b, c, d, e, f] =
        for {name, rating} <-
              [{"A", 2000}, {"B", 1900}, {"C", 1800}, {"D", 1700}, {"E", 1600}, {"F", 1500}] do
          Repo.insert!(%Player{
            tournament_id: t.id,
            name: name,
            fide_rating: rating,
            pairing_number: 2001 - rating
          })
        end

      r1 = Repo.insert!(%Round{tournament_id: t.id, number: 1, status: "finished"})
      r2 = Repo.insert!(%Round{tournament_id: t.id, number: 2, status: "playing"})

      for {w, b_, board, result} <- [
            {a, b, 1, "1-0"},
            {c, d, 2, "1-0"},
            {e, f, 3, "1/2-1/2"}
          ] do
        Repo.insert!(%Pairing{
          round_id: r1.id,
          board: board,
          white_player_id: w.id,
          black_player_id: b_.id,
          result: result
        })
      end

      # Round 2 is paired and nothing is in yet. E and F are split across two
      # different boards, and neither shares a board with A or C.
      [p1, p2, p3] =
        for {w, b_, board} <- [{a, c, 1}, {b, e, 2}, {d, f, 3}] do
          Repo.insert!(%Pairing{
            round_id: r2.id,
            board: board,
            white_player_id: w.id,
            black_player_id: b_.id,
            result: ""
          })
        end

      {t, %{a: a, b: b, c: c, d: d, e: e, f: f}, %{board1: p1, board2: p2, board3: p3}}
    end

    defp tiebreaks_by_name(t) do
      t
      |> Standings.standings()
      |> Map.new(&{&1.player.name, &1.tiebreaks})
    end

    test "reporting one board leaves players with no stake in it untouched" do
      {t, _players, %{board1: board1}} = mid_round_fixture()

      before = tiebreaks_by_name(t)

      # A v C reports. E and F are still playing, on other boards, and their
      # only opponent so far is each other.
      {:ok, _} = Tournaments.update_pairing_result(board1, "1-0")

      later = tiebreaks_by_name(t)

      # Nothing about E or F has changed in the world, so nothing about them
      # may change here. Before the fix both gained a phantom draw.
      assert later["E"] == before["E"]
      assert later["F"] == before["F"]
    end

    test "the phantom draw, named exactly" do
      {t, _players, %{board1: board1}} = mid_round_fixture()

      bh_before = tiebreaks_by_name(t)["E"]["BH"]
      {:ok, _} = Tournaments.update_pairing_result(board1, "1-0")
      bh_after = tiebreaks_by_name(t)["E"]["BH"]

      # E's Buchholz is the sum of E's opponents' adjusted scores. E has one
      # opponent, F, who drew with them and has played nothing since. F's
      # adjusted score cannot change because two other players finished a
      # game, and the whole defect was that it did.
      assert bh_after == bh_before
      assert bh_after == 0.5
    end

    test "Koya's 50% threshold does not move when one board reports" do
      {t, _players, %{board1: board1}} = mid_round_fixture()

      ks_before = tiebreaks_by_name(t)["E"]["KS"]
      {:ok, _} = Tournaments.update_pairing_result(board1, "1-0")
      ks_after = tiebreaks_by_name(t)["E"]["KS"]

      # Article 9.2's maximum score is over rounds that have FINISHED. Round 2
      # has not, so the threshold is still one round's worth of wins and the
      # set of opponents at or above 50% is unchanged.
      assert ks_after == ks_before
    end

    test "once the whole round is in, the horizon moves - and only then" do
      {t, _players, %{board1: b1, board2: b2, board3: b3}} = mid_round_fixture()

      before = tiebreaks_by_name(t)

      for p <- [b1, b2, b3], do: {:ok, _} = Tournaments.update_pairing_result(p, "1-0")

      later = tiebreaks_by_name(t)

      # The control that keeps the fix from being "ignore round 2 forever":
      # with every board in, round 2 is complete, it counts, and the numbers
      # legitimately move.
      refute later == before

      # No intermediate assertion here on purpose. Once two of the three
      # boards have reported, every remaining player either played in one of
      # them or has an opponent who did, so there is nobody left whose
      # numbers SHOULD be frozen - and a test that asserted otherwise would
      # be asserting the defect back into existence. The one-board case
      # above is where the isolation actually holds.
    end
  end

  ## ---------- bye_points_for_row/2: the same answer, without the N+1 ----------

  describe "bye_points_for_row/2" do
    # This is called once per rendered bye row inside four render loops (the
    # pool panel, the live round view, the public pairings page and the
    # print controller), and it used to fire a COUNT query every single
    # time - to answer a question only SWAR's `abs_nbfois` cap ever asks,
    # and that cap is unset on every tournament that is not a SWAR import
    # configured that way.
    #
    # The values below are pinned FIRST and deliberately cover every branch
    # of `absent_points/3`, because the whole point of skipping the query is
    # that it changes no number an arbiter sees. Each expectation is the
    # answer the version that always queried gave.
    defp absence_fixture(attrs) do
      tournament =
        Repo.insert!(
          struct(
            %Tournament{name: "Absence Scoring", type: "swiss", rounds_count: 5},
            attrs
          )
        )

      player =
        Repo.insert!(%Player{tournament_id: tournament.id, name: "Absentee", fide_rating: 1500})

      {tournament, player}
    end

    defp file_absences(tournament, player, rounds) do
      Repo.insert_all(
        "byes",
        Enum.map(rounds, fn round ->
          %{
            tournament_id: tournament.id,
            player_id: player.id,
            round: round,
            type: "absent"
          }
        end)
      )
    end

    defp row(player, round, type \\ "absent"),
      do: %{player_id: player.id, round: round, type: type}

    test "with no abs_value the absence is a plain loss, cap fields or not" do
      {t, p} = absence_fixture(%{abs_value: nil, abs_jusque: 2, abs_nbfois: 1})
      file_absences(t, p, [1, 2, 3])

      assert Standings.bye_points_for_row(row(p, 3), t) == t.points_loss
    end

    test "with abs_value and no caps every absence pays abs_value" do
      {t, p} = absence_fixture(%{abs_value: 0.5, abs_jusque: nil, abs_nbfois: nil})
      file_absences(t, p, [1, 2, 3, 4])

      for round <- 1..4 do
        assert Standings.bye_points_for_row(row(p, round), t) == 0.5
      end
    end

    test "the abs_jusque round cap is inclusive, and past it pays points_loss" do
      {t, p} = absence_fixture(%{abs_value: 0.5, abs_jusque: 3, abs_nbfois: nil})
      file_absences(t, p, [3, 4])

      assert Standings.bye_points_for_row(row(p, 3), t) == 0.5
      assert Standings.bye_points_for_row(row(p, 4), t) == t.points_loss
    end

    test "the abs_nbfois occurrence cap counts absences through the row's own round" do
      {t, p} = absence_fixture(%{abs_value: 0.5, abs_jusque: nil, abs_nbfois: 2})
      file_absences(t, p, [1, 2, 3])

      # First and second absence are inside the cap; the third is not. The
      # count is cumulative and inclusive of the round being scored, which
      # is the branch that needs the database at all.
      assert Standings.bye_points_for_row(row(p, 1), t) == 0.5
      assert Standings.bye_points_for_row(row(p, 2), t) == 0.5
      assert Standings.bye_points_for_row(row(p, 3), t) == t.points_loss
    end

    test "the occurrence cap counts only this player's own absences" do
      {t, p} = absence_fixture(%{abs_value: 0.5, abs_jusque: nil, abs_nbfois: 2})

      other =
        Repo.insert!(%Player{tournament_id: t.id, name: "Someone Else", fide_rating: 1400})

      file_absences(t, p, [3])
      file_absences(t, other, [1, 2])

      assert Standings.bye_points_for_row(row(p, 3), t) == 0.5
    end

    test "a requested-half or requested-zero row never consults the count at all" do
      {t, p} = absence_fixture(%{abs_value: 0.5, abs_jusque: 1, abs_nbfois: 1})
      file_absences(t, p, [1, 2, 3])

      assert Standings.bye_points_for_row(row(p, 3, "requested-half"), t) == t.points_draw
      assert Standings.bye_points_for_row(row(p, 3, "requested-zero"), t) == t.points_loss
    end

    test "an ordinary tournament renders a whole round of absences without a single count query" do
      {t, p} = absence_fixture(%{abs_value: nil, abs_jusque: nil, abs_nbfois: nil})
      rows = for round <- 1..8, do: row(p, round)
      file_absences(t, p, 1..8)

      {results, queries} =
        count_repo_queries(fn ->
          Enum.map(rows, &Standings.bye_points_for_row(&1, t))
        end)

      assert results == List.duplicate(t.points_loss, 8)

      assert queries == [],
             "rendering #{length(rows)} bye rows ran #{length(queries)} queries: " <>
               inspect(queries)
    end

    test "the count is still fetched where abs_nbfois can actually consult it" do
      # The control: the query is skipped because the answer cannot matter,
      # not because it stopped being asked. With the cap live it is asked,
      # and the numbers above prove it is asked correctly.
      {t, p} = absence_fixture(%{abs_value: 0.5, abs_jusque: nil, abs_nbfois: 2})
      file_absences(t, p, [1, 2, 3])

      {_results, queries} =
        count_repo_queries(fn ->
          Enum.map(1..3, &Standings.bye_points_for_row(row(p, &1), t))
        end)

      assert length(queries) == 3
    end

    # Ecto emits `[:pairings_engine, :repo, :query]` for every query it runs.
    # The handler runs in whichever process ran the query, so filtering on
    # the test's own pid keeps this file's `async: true` from picking up
    # another test's traffic.
    defp count_repo_queries(fun) do
      test_pid = self()
      ref = make_ref()
      handler_id = {__MODULE__, ref}

      :telemetry.attach(
        handler_id,
        [:pairings_engine, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == test_pid, do: send(test_pid, {ref, metadata.query})
        end,
        nil
      )

      result =
        try do
          fun.()
        after
          :telemetry.detach(handler_id)
        end

      {result, drain_queries(ref, [])}
    end

    defp drain_queries(ref, acc) do
      receive do
        {^ref, query} -> drain_queries(ref, [query | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end
  end

  describe "C.07 Article 10: rating-based tie-breaks and unrated players" do
    # Article 10, verbatim:
    #
    #   "These tie-breaks must be dropped from the tournament tie-break list
    #    when unrated players are present, unless detailed rules on the
    #    handling of unrated players are included in the tournament
    #    regulations or established and published by the Chief Arbiter before
    #    the start of the tournament."
    #
    # Note what the regulation does NOT provide: any rating to stand in for
    # an unrated opponent. There is no floor and no "leave them out of the
    # average" - both would be inventing the rule FIDE declined to write. The
    # only conforming behaviour is not to use the tie-break.
    #
    # What this replaces: `Player.rating/1` answers 0 for an unrated player,
    # correctly for its other callers, and `aro/3` averaged that in. A player
    # who faced 2000s and one unrated scored around half what they should
    # have, and dropped below anybody who happened to draw a full rated field
    # - in a tie-break that decides prizes.
    defp unrated_fixture do
      tournament =
        Repo.insert!(%Tournament{
          name: "Unrated present",
          type: "swiss",
          rounds_count: 1,
          tiebreaks: ~w(BH ARO)
        })

      [a, b] =
        for {name, rating} <- [{"Rated", 2000}, {"Unrated", 0}] do
          Repo.insert!(%Player{
            tournament_id: tournament.id,
            name: name,
            fide_rating: rating,
            pairing_number: 1
          })
        end

      {tournament, a, b}
    end

    test "an unrated entrant drops ARO from the list it is ranked on" do
      {tournament, _a, _b} = unrated_fixture()

      assert Standings.unrated_present?(tournament)
      assert Standings.dropped_tiebreaks(tournament) == ["ARO"]
      assert Standings.effective_tiebreaks(tournament) == ["BH"]
    end

    test "and the value is not computed at all, rather than computed wrongly" do
      # The old behaviour was a number - the wrong one. Absence is the point:
      # there is no correct number to show.
      {tournament, _a, _b} = unrated_fixture()

      [entry | _] = Standings.standings(tournament)

      refute Map.has_key?(entry.tiebreaks, "ARO")
    end

    test "a fully rated tournament is untouched" do
      # The guard must not cost anything to the ordinary case, which is every
      # tournament that has ratings for everybody.
      {tournament, _players} = fixture()

      refute Standings.unrated_present?(tournament)
      assert Standings.dropped_tiebreaks(tournament) == []
      assert "ARO" in Standings.effective_tiebreaks(tournament)

      [ea | _] = Standings.standings(tournament)
      assert ea.tiebreaks["ARO"] == 1750.0
    end

    test "adding one unrated player mid-event drops it" do
      # Article 10 turns on presence, not on who anybody played. One late
      # entrant with no rating is enough, and the standings must notice
      # without the tournament being reconfigured.
      {tournament, _players} = fixture()
      assert "ARO" in Standings.effective_tiebreaks(tournament)

      Repo.insert!(%Player{
        tournament_id: tournament.id,
        name: "Late",
        fide_rating: 0,
        pairing_number: 99
      })

      assert Standings.dropped_tiebreaks(tournament) == ["ARO"]
    end

    test "a national rating still counts as rated" do
      # `Player.rating/1` falls back to the national rating, so a player with
      # no FIDE rating but a national one is NOT unrated and must not drop
      # the tie-break for everybody.
      {tournament, _players} = fixture()

      Repo.insert!(%Player{
        tournament_id: tournament.id,
        name: "National only",
        fide_rating: 0,
        national_rating: 1650,
        pairing_number: 98
      })

      refute Standings.unrated_present?(tournament)
      assert "ARO" in Standings.effective_tiebreaks(tournament)
    end
  end
end
