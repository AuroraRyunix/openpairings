defmodule PairingsEngine.ManualPairingTest do
  @moduledoc """
  Manual pairing alteration (VCL4THP Q63-Q69, the TEC Manual's MPA PIBE):
  what a hand-made board breaks (Q66, Q67), the pairing checker at the end
  of a session (Q68), the PIBE line and where the TRF carries it (Q69,
  Q113), and a round created by hand when no legal pairing exists (Q63).
  The Pairings page's side is `manual_pairing_live_test.exs`.
  """
  # async: false - it pairs rounds, and SQLite takes one writer.
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{
    ManualPairing,
    Pairing,
    Repo,
    TournamentExport,
    TournamentImport,
    Tournaments,
    TrfExport
  }

  alias PairingsEngine.Tournaments.{Player, Round, Tournament}
  alias PairingsEngine.Tournaments.Pairing, as: Board

  defp tournament(attrs \\ []) do
    Repo.insert!(
      struct(
        Tournament,
        Map.merge(
          %{
            name: "Manual pairing",
            type: "swiss",
            rounds_count: 5,
            tiebreaks: ~w(BH SB),
            round_dates: ~w(2026-09-01 2026-09-08 2026-09-15 2026-09-22 2026-09-29)
          },
          Map.new(attrs)
        )
      )
    )
  end

  defp players(t, names) do
    for {name, i} <- Enum.with_index(names) do
      {:ok, p} =
        Tournaments.create_player(t.id, %{
          tournament_id: t.id,
          name: name,
          fide_rating: 2000 - 50 * i
        })

      p
    end
  end

  defp play_round!(t) do
    {:ok, round} = Pairing.pair_next_round(Repo.reload!(t))
    round = Tournaments.get_round(t.id, round.number)

    for {p, i} <- Enum.with_index(round.pairings), p.black_player_id do
      {:ok, _} = Tournaments.update_pairing_result(p, Enum.at(~w(1-0 0-1 1/2-1/2), rem(i, 3)))
    end

    Tournaments.get_round(t.id, round.number)
  end

  # A round written by hand, with the colours and results a test needs.
  defp insert_round!(t, number, boards) do
    round = Repo.insert!(%Round{tournament_id: t.id, number: number, status: "finished"})

    for {{w, b, result}, board} <- Enum.with_index(boards, 1) do
      Repo.insert!(%Board{
        round_id: round.id,
        board: board,
        white_player_id: w.id,
        black_player_id: b && b.id,
        result: result
      })
    end

    :ok = Tournaments.freeze_round_display_boards!(round.id)
    round
  end

  defp kinds(warnings), do: warnings |> Enum.map(& &1.kind) |> Enum.sort()

  # Five players with a known history: two rounds written by hand, and a
  # third (to be judged) that exists so the field can be rebuilt.
  defp history(rounds_count) do
    t = tournament(rounds_count: rounds_count)
    [p1, p2, p3, p4, p5] = ps = players(t, ~w(Ann Ben Cas Dan Eva))

    for {p, n} <- Enum.with_index(ps, 1) do
      p |> Ecto.Changeset.change(pairing_number: n) |> Repo.update!()
    end

    # Round 1: Ann (W) - Ben, Cas (W) - Dan, Eva the pairing-allocated bye.
    insert_round!(t, 1, [{p1, p2, "1-0"}, {p3, p4, "1-0"}, {p5, nil, "bye"}])
    # Round 2: Ann (W) - Cas, Dan (W) - Eva, Ben the bye.
    insert_round!(t, 2, [{p1, p3, "1/2-1/2"}, {p4, p5, "1/2-1/2"}, {p2, nil, "bye"}])
    insert_round!(t, 3, [{p1, p4, ""}, {p2, p3, ""}, {p5, nil, "bye"}])

    t = Repo.reload!(t)
    {:ok, field} = ManualPairing.field(t, 3)
    {t, field, ps}
  end

  describe "warnings/4 - what a hand-made board breaks (Q66, Q67)" do
    test "a game already played over the board, with the round it was played in" do
      {t, field, [ann, ben | _]} = history(5)

      assert [%{kind: :rematch, round: 1} | _] =
               ManualPairing.warnings(field, t, 3, [{ben, ann} |> ids()])
    end

    test "a prohibited pairing" do
      {t, _field, [ann, _ben, _cas, _dan, eva]} = history(5)
      {:ok, _} = Tournaments.add_forbidden_pairing(t, ann.id, eva.id)
      {:ok, field} = ManualPairing.field(Repo.reload!(t), 3)

      assert :forbidden in kinds(ManualPairing.warnings(field, t, 3, [ids({eva, ann})]))
    end

    test "a pairing-allocated bye to a player who already had one, and none to one who did not" do
      {t, field, [ann, _ben, _cas, _dan, eva]} = history(5)

      assert [%{kind: :bye, reason: :pairing_bye, players: [id]}] =
               ManualPairing.warnings(field, t, 3, [{eva.id, :pab}])

      assert id == eva.id
      assert ManualPairing.warnings(field, t, 3, [{ann.id, :pab}]) == []
    end

    test "three same colours in a row and a difference above two, before the last round" do
      {t, field, [ann, _ben, _cas, dan, _eva]} = history(5)

      # Ann had White in rounds 1 and 2: a third is both.
      assert kinds(ManualPairing.warnings(field, t, 3, [ids({ann, dan})])) ==
               [:colour_imbalance, :colour_three]
    end

    test "no colour warning in the last round" do
      {t, field, [ann, _ben, _cas, dan, _eva]} = history(3)
      warnings = ManualPairing.warnings(field, t, 3, [ids({ann, dan})])
      refute Enum.any?(warnings, &(&1.kind in [:colour_three, :colour_imbalance]))
    end

    test "both players getting the colour opposite to the one they are due" do
      {t, field, [_ann, ben, _cas, dan, _eva]} = history(5)

      # Dan (Black, then White) is due Black; Ben (Black, then the bye) is
      # due White.
      assert ManualPairing.warnings(field, t, 3, [ids({dan, ben})]) == [
               %{kind: :wrong_colours, players: [dan.id, ben.id]}
             ]

      refute :wrong_colours in kinds(ManualPairing.warnings(field, t, 3, [ids({ben, dan})]))
    end

    test "a legal board breaks nothing" do
      {t, field, [_ann, ben, _cas, dan, _eva]} = history(5)
      # Ben: Black then a bye - due White. Dan: Black, White - due Black.
      assert ManualPairing.warnings(field, t, 3, [ids({ben, dan})]) == []
    end
  end

  defp ids({a, b}), do: {a.id, b.id}

  describe "a session and the pairing checker at its end (Q65, Q68, Q69)" do
    setup do
      t = tournament()
      ps = players(t, ~w(Ann Ben Cas Dan))
      {:ok, round} = Pairing.pair_next_round(Repo.reload!(t))
      %{t: Repo.reload!(t), players: ps, round: Tournaments.get_round(t.id, round.number)}
    end

    test "opens once, remembers where it started, and closes", %{t: t, round: round} do
      refute ManualPairing.open?(round)
      assert {:ok, true} = ManualPairing.start(round)
      assert {:ok, false} = ManualPairing.start(round)
      assert ManualPairing.open_round(t.id) == 1

      round = Tournaments.get_round(t.id, 1)
      assert round.mpa_session["before"] == ManualPairing.boards(round)

      assert :ok = ManualPairing.finish(round, :keep)
      assert ManualPairing.open_round(t.id) == nil
    end

    test "boards that are not the checker's: its pairing, the difference and the PIBE line",
         %{t: t, round: round, players: [ann, ben, cas, dan]} do
      {:ok, _} = ManualPairing.start(round)
      # The engine pairs Ann-Cas and Dan-Ben; Cas and Dan trade seats.
      {:ok, _} = Tournaments.swap_players_in_round(round, cas.id, dan.id)
      round = Tournaments.get_round(t.id, 1)

      assert {:differs, info} = ManualPairing.assess(t, round)
      assert Enum.sort(info.correct) == Enum.sort([{ann.id, cas.id}, {dan.id, ben.id}])
      assert Enum.sort(info.added) == Enum.sort([{ann.id, dan.id}, {cas.id, ben.id}])
      assert info.line == "MPA @ Round 1: 1-3 4-2 => 1-4 3-2"

      :ok = ManualPairing.finish(round, {:set, info.line})
      round = Tournaments.get_round(t.id, 1)
      assert round.mpa_pibe == "MPA @ Round 1: 1-3 4-2 => 1-4 3-2"
      refute ManualPairing.open?(round)
    end

    test "boards back where they started: nothing to check", %{t: t, round: round} do
      [first | _] = round.pairings
      {:ok, _} = ManualPairing.start(round)

      {:ok, _} =
        Tournaments.swap_players_in_round(round, first.white_player_id, first.black_player_id)

      round = Tournaments.get_round(t.id, 1)
      assert {:differs, _} = ManualPairing.assess(t, round)

      {:ok, _} =
        Tournaments.swap_players_in_round(round, first.white_player_id, first.black_player_id)

      assert ManualPairing.assess(t, Tournaments.get_round(t.id, 1)) == :unchanged
    end

    test "re-entered and put back to the checker's pairing: the PIBE goes",
         %{t: t, round: round, players: [_ann, _ben, cas, dan]} do
      {:ok, _} = Tournaments.swap_players_in_round(round, cas.id, dan.id)
      round = Tournaments.get_round(t.id, 1)
      :ok = ManualPairing.finish(round, {:set, "MPA @ Round 1: 1-3 4-2 => 1-4 3-2"})

      round = Tournaments.get_round(t.id, 1)
      {:ok, _} = ManualPairing.start(round)
      {:ok, _} = Tournaments.swap_players_in_round(round, cas.id, dan.id)

      assert {:matches, _} = ManualPairing.assess(t, Tournaments.get_round(t.id, 1))
    end

    test "an empty seat cannot be finished", %{t: t, round: round, players: [ann | _]} do
      {:ok, _} = ManualPairing.start(round)
      {:ok, _} = Tournaments.vacate_seat(round, ann.id)
      round = Tournaments.get_round(t.id, 1)
      assert {:error, {:vacant, 1}} = ManualPairing.assess(t, round)
    end

    test "the TRF carries the PIBE as a ### line; the file sent for rating does not",
         %{t: t, round: round} do
      :ok = ManualPairing.finish(round, {:set, "MPA @ Round 1: 1-3 4-2 => 1-4 3-2"})

      {:ok, text} = TrfExport.export(t)
      assert text =~ "\r\n### MPA @ Round 1: 1-3 4-2 => 1-4 3-2\r\n"

      {:ok, rating} = TrfExport.export(t, nil, for: :rating)
      refute rating =~ "###"
    end

    test "the PIBE travels with a tournament export; an open session does not",
         %{t: t, round: round} do
      {:ok, _} = ManualPairing.start(round)
      round = Tournaments.get_round(t.id, 1)
      :ok = ManualPairing.finish(round, {:set, "MPA @ Round 1: 1-3 4-2 => 1-4 3-2"})
      {:ok, _} = ManualPairing.start(Tournaments.get_round(t.id, 1))

      envelope =
        t
        |> Repo.reload!()
        |> TournamentExport.export_tournament()
        |> Jason.encode!()
        |> Jason.decode!()

      [exported] = hd(envelope["tournaments"])["rounds"]
      assert exported["mpa_pibe"] == "MPA @ Round 1: 1-3 4-2 => 1-4 3-2"
      refute Map.has_key?(exported, "mpa_session")

      user =
        Repo.insert!(%PairingsEngine.Accounts.User{
          email: "mpa#{System.unique_integer([:positive])}@example.com",
          confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
        })

      assert {:ok, [copy]} =
               TournamentImport.import(envelope, PairingsEngine.Accounts.Scope.for_user(user))

      copied = Tournaments.get_round(copy.id, 1)
      assert copied.mpa_pibe == "MPA @ Round 1: 1-3 4-2 => 1-4 3-2"
      assert copied.mpa_session == nil
    end
  end

  describe "no legal pairing: a round created by hand (Q63)" do
    test "three players, four rounds: round 4 has no legal pairing and is created empty" do
      t = tournament(rounds_count: 4)
      [ann, ben, cas] = players(t, ~w(Ann Ben Cas))

      for _ <- 1..3, do: play_round!(t)

      assert {:error, {:no_legal_pairing, text}} = Pairing.pair_next_round(Repo.reload!(t))
      assert text =~ "no legal pairing"

      assert {:ok, round} = Pairing.create_round_by_hand(Repo.reload!(t))
      assert round.number == 4
      assert round.pairings == []

      pool = t.id |> Tournaments.list_round_pool(4) |> Enum.map(& &1.player_id) |> Enum.sort()
      assert pool == Enum.sort([ann.id, ben.id, cas.id])

      {:ok, _} = ManualPairing.start(round, [])
      {:ok, _} = Tournaments.pair_from_pool(round, ann.id, ben.id, 1)
      {:ok, _} = Tournaments.award_pool_bye(Tournaments.get_round(t.id, 4), cas.id, 2)

      round = Tournaments.get_round(t.id, 4)
      assert {:differs, %{correct: :none, line: line}} = ManualPairing.assess(t, round)
      assert line =~ ~r/^MPA @ Round 4: no legal pairing => \d-\d \d=PAB$/
    end

    test "only an individual Swiss paired a round at a time" do
      t = tournament(pairing_system: "keizer")
      players(t, ~w(Ann Ben))
      assert {:error, :not_by_hand} = Pairing.create_round_by_hand(t)
    end
  end

  test "a player is not seated twice by a pool bye" do
    t = tournament()
    [ann | _] = players(t, ~w(Ann Ben Cas Dan))
    {:ok, round} = Pairing.pair_next_round(Repo.reload!(t))
    round = Tournaments.get_round(t.id, round.number)

    assert {:error, :already_seated} = Tournaments.award_pool_bye(round, ann.id, 9)
    refute Repo.get_by(Board, round_id: round.id, board: 9)
    assert %Player{} = Repo.get!(Player, ann.id)
  end
end
