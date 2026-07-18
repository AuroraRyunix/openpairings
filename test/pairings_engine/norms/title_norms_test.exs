defmodule PairingsEngine.Norms.TitleNormsTest do
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.Norms.TitleNorms
  alias PairingsEngine.Repo
  alias PairingsEngine.Tournaments.{Tournament, Player, Round, Pairing}

  # ---------------------------------------------------------------------
  # dp table (B.01 art. 1.4.9)
  # ---------------------------------------------------------------------

  describe "dp table" do
    test "spot values match the handbook verbatim" do
      assert TitleNorms.dp_for_percent(100) == 800
      assert TitleNorms.dp_for_percent(76) == 202
      assert TitleNorms.dp_for_percent(66) == 117
      assert TitleNorms.dp_for_percent(50) == 0
      assert TitleNorms.dp_for_percent(35) == -110
      assert TitleNorms.dp_for_percent(0) == -800
    end

    test "the table is perfectly antisymmetric: dp(p) == -dp(100 - p)" do
      for p <- 0..100 do
        assert TitleNorms.dp_for_percent(p) == -TitleNorms.dp_for_percent(100 - p),
               "dp(#{p}) != -dp(#{100 - p})"
      end
    end
  end

  # ---------------------------------------------------------------------
  # end-to-end evaluation on a hand-built tournament
  # ---------------------------------------------------------------------

  # The candidate plays 9 opponents, one round each. Opponent list is built
  # so an IM norm passes every B.01 gate with hand-checkable numbers:
  #
  #   ratings: 2450 2400 2350 2300 2250 2200 2150 2100 + one unrated (-> 1400,
  #   the single lowest, floor-raised to 2050 for the IM norm per 1.4.6.3)
  #   adjusted sum = 2450+2400+2350+2300+2250+2200+2150+2100+2050 = 20250
  #   Ra = 20250 / 9 = 2250 (>= 2230 required for IM)
  #
  #   titles: IM, IM, GM, IM (4 counting for "IM or higher"; need
  #   max(3, ceil(9/3)) = 3) + FM (titled but not high) = 5 of 9 titled
  #   (>= 50%).
  #
  #   federations (candidate is BEL): 3x BEL (max allowed 3/5 of 9 rounded
  #   down = 5), plus FRA FRA NED NED GER ESP -> 4 foreign federations
  #   (>= 2); largest single group 3 (max 2/3 of 9 rounded down = 6).
  #
  #   results: 6 wins, 1 draw, 2 losses = 6.5/9 = 72.22% -> 72% -> dp 166.
  #   Rp = 2250 + 166 = 2416: IM says >= 2450 -> FAILS on performance alone…
  #   so give 7 wins 1 draw 1 loss = 7.5/9 = 83.33% -> 83% -> dp 273.
  #   Rp = 2250 + 273 = 2523 >= 2450. IM norm achieved.
  #   GM norm from the same games: floor-raise to 2200 changes the unrated
  #   opponent to 2200 -> sum 20400 -> Ra ~ 2266.67 -> 2267 < 2380 -> fails
  #   avg gate (and performance 2267 + 273 = 2540 < 2600) -> not achieved.
  defp im_norm_fixture do
    tournament =
      Repo.insert!(%Tournament{
        name: "Norm Test Open",
        type: "swiss",
        rounds_count: 9,
        federation: "BEL",
        points_win: 1.0,
        points_draw: 0.5,
        points_loss: 0.0
      })

    candidate =
      Repo.insert!(%Player{
        tournament_id: tournament.id,
        name: "Candidate, Ann",
        sex: "w",
        federation: "BEL",
        fide_rating: 2300,
        pairing_number: 1
      })

    opponents =
      [
        {2450, "IM", "FRA"},
        {2400, "IM", "FRA"},
        {2350, "GM", "NED"},
        {2300, "IM", "NED"},
        {2250, "FM", "GER"},
        {2200, "", "ESP"},
        {2150, "", "BEL"},
        {2100, "", "BEL"},
        # Unrated (fide_rating 0): counts as 1400, and as THE single lowest
        # is floor-raised (2050 for IM, 2200 for GM).
        {0, "", "BEL"}
      ]
      |> Enum.with_index(2)
      |> Enum.map(fn {{rating, title, fed}, n} ->
        Repo.insert!(%Player{
          tournament_id: tournament.id,
          name: "Opp #{n}",
          title: title,
          federation: fed,
          fide_rating: rating,
          pairing_number: n
        })
      end)

    # 7 wins, 1 draw (vs Opp 2), 1 loss (vs Opp 3) = 7.5/9.
    results =
      ["1-0", "1/2-1/2", "0-1", "1-0", "1-0", "1-0", "1-0", "1-0", "1-0"]

    opponents
    |> Enum.zip(results)
    |> Enum.with_index(1)
    |> Enum.each(fn {{opp, result}, round_number} ->
      round =
        Repo.insert!(%Round{tournament_id: tournament.id, number: round_number, status: "finished"})

      Repo.insert!(%Pairing{
        round_id: round.id,
        board: 1,
        white_player_id: candidate.id,
        black_player_id: opp.id,
        result: result
      })
    end)

    {tournament, candidate, opponents}
  end

  test "a hand-computed IM norm is achieved, with the exact Ra/Rp the regulations produce" do
    {tournament, candidate, _} = im_norm_fixture()

    result = TitleNorms.evaluate(tournament) |> Map.fetch!(candidate.id)

    im = Enum.find(result.verdicts, &(&1.title == "IM"))
    assert im.achieved?
    # Ra: (2450+2400+2350+2300+2250+2200+2150+2100+2050)/9 = 2250 — the
    # unrated opponent went 0 -> 1400 -> floor-raised to 2050.
    assert im.avg_opponent_rating == 2250
    # 7.5/9 = 83.33% -> 83% -> dp 273 -> Rp 2523.
    assert im.performance == 2523
    assert im.score == 7.5
    assert im.games == 9
    assert Enum.all?(im.checks, & &1.ok?)

    # Best achieved norm is IM (GM fails, see below).
    assert result.best.title == "IM"
  end

  test "the same games do NOT amount to a GM norm (avg + performance both short), with the failing checks named" do
    {tournament, candidate, _} = im_norm_fixture()

    result = TitleNorms.evaluate(tournament) |> Map.fetch!(candidate.id)
    gm = Enum.find(result.verdicts, &(&1.title == "GM"))

    refute gm.achieved?
    # GM floor raises the unrated 1400 to 2200 instead: sum 20400 -> 2266.67
    # -> 2267 (0.5-up rounding not hit here).
    assert gm.avg_opponent_rating == 2267
    assert gm.performance == 2267 + 273

    failing = gm.checks |> Enum.reject(& &1.ok?) |> Enum.map(& &1.name)
    assert :avg_opponent_rating in failing
    assert :performance in failing
    # The GM-title-opponent gate also fails: only 1 GM among the opponents.
    assert :high_titled_opponents in failing
  end

  test "women's titles are evaluated only for women" do
    {tournament, candidate, _} = im_norm_fixture()

    result = TitleNorms.evaluate(tournament) |> Map.fetch!(candidate.id)
    assert Enum.map(result.verdicts, & &1.title) == ~w(GM IM WGM WIM)

    # A male player with the same profile only gets GM/IM evaluated.
    {:ok, _} = PairingsEngine.Tournaments.update_player(candidate, %{sex: "m"})
    tournament = Repo.reload!(tournament)

    result = TitleNorms.evaluate(tournament) |> Map.fetch!(candidate.id)
    assert Enum.map(result.verdicts, & &1.title) == ~w(GM IM)
  end

  test "forfeits and byes never count as games (B.01 1.4.2.3)" do
    tournament =
      Repo.insert!(%Tournament{
        name: "Short",
        type: "swiss",
        rounds_count: 3,
        federation: "BEL",
        points_win: 1.0,
        points_draw: 0.5,
        points_loss: 0.0
      })

    a = Repo.insert!(%Player{tournament_id: tournament.id, name: "A", federation: "BEL", fide_rating: 2200, pairing_number: 1})
    b = Repo.insert!(%Player{tournament_id: tournament.id, name: "B", federation: "FRA", fide_rating: 2300, pairing_number: 2})

    r1 = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})
    r2 = Repo.insert!(%Round{tournament_id: tournament.id, number: 2, status: "finished"})
    r3 = Repo.insert!(%Round{tournament_id: tournament.id, number: 3, status: "finished"})

    # One real game, one forfeit win, one pairing-allocated bye.
    Repo.insert!(%Pairing{round_id: r1.id, board: 1, white_player_id: a.id, black_player_id: b.id, result: "1-0"})
    Repo.insert!(%Pairing{round_id: r2.id, board: 1, white_player_id: a.id, black_player_id: b.id, result: "1-0FF"})
    Repo.insert!(%Pairing{round_id: r3.id, board: 1, white_player_id: a.id, black_player_id: nil, result: "bye"})

    result = TitleNorms.evaluate(tournament) |> Map.fetch!(a.id)

    assert result.games == 1
    im = Enum.find(result.verdicts, &(&1.title == "IM"))
    refute im.achieved?
    games_check = Enum.find(im.checks, &(&1.name == :games))
    refute games_check.ok?
    assert games_check.detail =~ "1 counted game"
  end

  test "only the single lowest opponent is floor-raised (B.01 1.4.6.3)" do
    # Two sub-floor opponents: 1400 (unrated) and 1800. Only the 1400 (the
    # lowest) is raised to the WIM floor 1850; the 1800 stays 1800.
    tournament =
      Repo.insert!(%Tournament{
        name: "Floor",
        type: "swiss",
        rounds_count: 2,
        federation: "BEL",
        points_win: 1.0,
        points_draw: 0.5,
        points_loss: 0.0
      })

    a = Repo.insert!(%Player{tournament_id: tournament.id, name: "A", sex: "w", federation: "BEL", fide_rating: 2000, pairing_number: 1})
    low1 = Repo.insert!(%Player{tournament_id: tournament.id, name: "U", federation: "FRA", fide_rating: 0, pairing_number: 2})
    low2 = Repo.insert!(%Player{tournament_id: tournament.id, name: "L", federation: "NED", fide_rating: 1800, pairing_number: 3})

    r1 = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})
    r2 = Repo.insert!(%Round{tournament_id: tournament.id, number: 2, status: "finished"})
    Repo.insert!(%Pairing{round_id: r1.id, board: 1, white_player_id: a.id, black_player_id: low1.id, result: "1-0"})
    Repo.insert!(%Pairing{round_id: r2.id, board: 1, white_player_id: a.id, black_player_id: low2.id, result: "1-0"})

    result = TitleNorms.evaluate(tournament) |> Map.fetch!(a.id)
    wim = Enum.find(result.verdicts, &(&1.title == "WIM"))

    # (1850 + 1800) / 2 = 1825 — NOT (1850 + 1850) / 2 = 1850.
    assert wim.avg_opponent_rating == 1825
  end

  test "custom club scoring converts back to standard points for the score percentage" do
    # SWAR-style 2-1-0: a win awards 2.0 configured points but must count
    # as 1.0 standard for the 35%-score and dp lookups.
    tournament =
      Repo.insert!(%Tournament{
        name: "Club 210",
        type: "swiss",
        rounds_count: 1,
        federation: "BEL",
        points_win: 2.0,
        points_draw: 1.0,
        points_loss: 0.0
      })

    a = Repo.insert!(%Player{tournament_id: tournament.id, name: "A", federation: "BEL", fide_rating: 2000, pairing_number: 1})
    b = Repo.insert!(%Player{tournament_id: tournament.id, name: "B", federation: "FRA", fide_rating: 2000, pairing_number: 2})

    r1 = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})
    Repo.insert!(%Pairing{round_id: r1.id, board: 1, white_player_id: a.id, black_player_id: b.id, result: "1-0"})

    result = TitleNorms.evaluate(tournament) |> Map.fetch!(a.id)
    im = Enum.find(result.verdicts, &(&1.title == "IM"))

    # 1 win of 1 game = 100% (not 200%!) — dp(100) = 800. The 2000-rated
    # opponent is the single lowest and is floor-raised to the IM floor
    # 2050 (1.4.6.3), so Rp = 2050 + 800.
    assert im.score == 1.0
    assert im.performance == 2850
  end
end
