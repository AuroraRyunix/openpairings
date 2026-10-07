defmodule PairingsEngine.FullPointByeTest do
  @moduledoc """
  The arbiter's full-point bye (VCL4THP Q177-Q179, TRF `F`): given to a
  player sitting a round out, kept apart from the pairing-allocated bye
  (`U`), scored as a win, sent to the engine as `F` (so C.04.3 [C2] rules
  the player out of the pairing-allocated bye afterwards, which the manual
  pairing checks see), counted as an unplayed round that is not voluntary,
  written `F` in the TRF with a `###` line, and read back from a TRF and a
  backup as the same kind. The Pairings page's side is
  `full_point_bye_live_test.exs`.
  """
  # async: false - it pairs rounds, and SQLite takes one writer.
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{
    ManualPairing,
    Pairing,
    Repo,
    Standings,
    TournamentExport,
    TournamentImport,
    Tournaments,
    TrfExport,
    TrfImport
  }

  alias PairingsEngine.Tournaments.{Round, Tournament}
  alias PairingsEngine.Tournaments.Pairing, as: Board

  defp tournament(attrs \\ []) do
    Repo.insert!(
      struct(
        Tournament,
        Map.merge(
          %{
            name: "Full-point bye",
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

      p |> Ecto.Changeset.change(pairing_number: i + 1) |> Repo.update!()
    end
  end

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
    Tournaments.get_round(t.id, number)
  end

  defp bye_type(t, player, round) do
    Repo.one(
      from b in "byes",
        where: b.tournament_id == ^t.id and b.player_id == ^player.id and b.round == ^round,
        select: b.type
    )
  end

  # Five players: round 1 is Ann-Ben and Cas-Dan, and Eva sits it out with
  # a full-point bye.
  defp with_fpb do
    t = tournament()
    [ann, ben, cas, dan, eva] = ps = players(t, ~w(Ann Ben Cas Dan Eva))
    round = insert_round!(t, 1, [{ann, ben, "1-0"}, {cas, dan, "1/2-1/2"}])
    assert {:ok, _} = Tournaments.award_full_point_bye(round, eva.id)
    {Repo.reload!(t), ps, Tournaments.get_round(t.id, 1), eva}
  end

  describe "giving one (Q177)" do
    test "a pool player's round becomes a full-point byes row, not a board" do
      {t, _ps, round, eva} = with_fpb()

      assert bye_type(t, eva, 1) == "full-point"
      refute Enum.any?(round.pairings, &(&1.white_player_id == eva.id))
      assert [%{type: "full-point"}] = Tournaments.list_byes_for_round(t.id, 1)
    end

    test "it replaces the absence that put the player in the pool, and goes back to one" do
      t = tournament()
      [ann, ben, cas] = players(t, ~w(Ann Ben Cas))
      round = insert_round!(t, 1, [{ann, ben, "1-0"}])

      Repo.insert_all("byes", [
        %{tournament_id: t.id, player_id: cas.id, round: 1, type: "absent"}
      ])

      assert {:ok, _} = Tournaments.award_full_point_bye(round, cas.id)
      assert bye_type(t, cas, 1) == "full-point"

      assert {:ok, _} = Tournaments.withdraw_full_point_bye(round, cas.id)
      assert bye_type(t, cas, 1) == "absent"
      assert {:error, :no_full_point_bye} = Tournaments.withdraw_full_point_bye(round, cas.id)
    end

    test "refused for a seated player, and for Keizer and team events" do
      t = tournament()
      [ann, ben, cas] = players(t, ~w(Ann Ben Cas))
      round = insert_round!(t, 1, [{ann, ben, "1-0"}])
      assert {:error, :already_seated} = Tournaments.award_full_point_bye(round, ann.id)

      keizer = t |> Ecto.Changeset.change(pairing_system: "keizer") |> Repo.update!()
      refute Tournaments.full_point_bye_supported?(keizer)

      assert {:error, :full_point_bye_unsupported} =
               Tournaments.award_full_point_bye(round, cas.id)
    end
  end

  describe "what it is worth and how it counts" do
    test "a win's points in the standings, an unplayed round that is not voluntary" do
      {t, _ps, _round, eva} = with_fpb()

      entry = t |> Standings.standings() |> Enum.find(&(&1.player.id == eva.id))
      assert entry.points == t.points_win

      [game] = Enum.filter(entry.games, &(&1.round == 1))
      assert game.bye_type == "full-point"
      refute game.played
      refute game.voluntary
    end

    test "the engine reads F for it - after which [C2] rules the player out of the PAB" do
      {t, [ann, ben, cas, dan, eva], _round, _} = with_fpb()

      rows = Pairing.trf_player_rows(t, Tournaments.list_players(t.id))
      eva_row = Enum.find(rows, &(&1.id == eva.id))
      assert [%{result: "F", opponent_rank: nil}] = eva_row.games
      assert eva_row.points == t.points_win

      # Round 2, by hand: Eva on the pairing-allocated bye. The manual
      # pairing checks (the TEC Manual's MPA, Level 3) name the reason.
      insert_round!(t, 2, [{ann, cas, ""}, {ben, dan, ""}, {eva, nil, "bye"}])
      {:ok, field} = ManualPairing.field(Repo.reload!(t), 2)

      assert [%{kind: :bye, reason: :full_point_bye}] =
               ManualPairing.warnings(field, t, 2, [{eva.id, :pab}])
    end
  end

  describe "the TRF (Q179) and the way back in" do
    test "written F, with a ### line - never in the file sent for rating" do
      {t, _ps, _round, eva} = with_fpb()

      {:ok, text} = TrfExport.export(t)
      assert text =~ "### FPB @ Round 1: #{eva.pairing_number}=FPB"

      eva_line = text |> String.split("\r\n") |> Enum.find(&(&1 =~ "Eva"))
      assert eva_line =~ "0000 - F"

      {:ok, rating} = TrfExport.export(t, nil, for: :rating)
      refute rating =~ "###"
      assert rating |> String.split("\r\n") |> Enum.find(&(&1 =~ "Eva")) =~ "0000 - F"
    end

    test "a TRF's F comes back as the full-point bye" do
      {t, _ps, _round, _eva} = with_fpb()
      {:ok, text} = TrfExport.export(t)

      assert {:ok, copy, _warnings} = TrfImport.import_text(text, user_scope())
      eva = copy.id |> Tournaments.list_players() |> Enum.find(&(&1.name =~ "Eva"))
      assert bye_type(copy, eva, 1) == "full-point"
    end

    test "a backup keeps it" do
      {t, _ps, _round, _eva} = with_fpb()

      envelope =
        t |> TournamentExport.export_tournament() |> Jason.encode!() |> Jason.decode!()

      assert {:ok, [copy]} = TournamentImport.import(envelope, user_scope())
      eva = copy.id |> Tournaments.list_players() |> Enum.find(&(&1.name == "Eva"))
      assert bye_type(copy, eva, 1) == "full-point"
    end
  end

  defp user_scope do
    user =
      Repo.insert!(%PairingsEngine.Accounts.User{
        email: "fpb#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    PairingsEngine.Accounts.Scope.for_user(user)
  end
end
