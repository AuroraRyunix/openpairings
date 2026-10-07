defmodule PairingsEngine.RatingCorrectionTest do
  @moduledoc """
  A result corrected for the rating report only (C.04.2:4.3, VCL4THP
  Q192/Q193): found wrong after the end of the next round, it stays what it
  was for the pairings and the standings, and the TRF26 report carries the
  corrected one in its `001` records with a `###` line naming the result
  the event used. The engine's input is untouched. The Pairings page's side
  is `rating_correction_live_test.exs`.
  """
  # async: false - SQLite takes one writer.
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{
    Pairing,
    Repo,
    Standings,
    TournamentExport,
    TournamentImport,
    Tournaments,
    TrfExport
  }

  alias PairingsEngine.Tournaments.{Round, Tournament}
  alias PairingsEngine.Tournaments.Pairing, as: Board

  defp tournament do
    Repo.insert!(%Tournament{
      name: "Rating correction",
      type: "swiss",
      rounds_count: 5,
      tiebreaks: ~w(BH SB),
      round_dates: ~w(2026-09-01 2026-09-08 2026-09-15 2026-09-22 2026-09-29)
    })
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

  # Four players, `played` rounds with every result in. Round 1 board 1 is
  # Ann (1) - Ben (2), 1-0.
  defp event(played) do
    t = tournament()
    [ann, ben, cas, dan] = ps = players(t, ~w(Ann Ben Cas Dan))
    insert_round!(t, 1, [{ann, ben, "1-0"}, {cas, dan, "1-0"}])
    if played >= 2, do: insert_round!(t, 2, [{ann, cas, "1/2-1/2"}, {ben, dan, "1-0"}])
    if played >= 3, do: insert_round!(t, 3, [{dan, ann, "0-1"}, {cas, ben, "1/2-1/2"}])
    {Repo.reload!(t), ps}
  end

  defp board(t, round, n),
    do:
      t.id |> Tournaments.get_round(round) |> Map.fetch!(:pairings) |> Enum.find(&(&1.board == n))

  defp line(text, name), do: text |> String.split("\r\n") |> Enum.find(&(&1 =~ name))

  describe "recording one (Q192)" do
    test "only once the next round is over; the board keeps its result" do
      {t, _} = event(2)

      assert {:error, :rating_correction_too_early} =
               Tournaments.set_rating_correction(board(t, 2, 1), "0-1")

      assert {:ok, corrected} = Tournaments.set_rating_correction(board(t, 1, 1), "0-1")
      assert corrected.result == "1-0"
      assert corrected.rating_result == "0-1"

      assert [%{round: 1, board: 1, result: "1-0", rating_result: "0-1"}] =
               Tournaments.list_rating_corrections(t.id)
    end

    test "a round FIDE mode has closed takes it, where an ordinary correction is refused" do
      {t, _} = event(3)
      pairing = board(t, 1, 1)

      assert {:error, :round_closed_in_fide_mode} =
               Tournaments.update_pairing_result(pairing, "0-1")

      assert {:ok, %{rating_result: "0-1"}} = Tournaments.set_rating_correction(pairing, "0-1")
    end

    test "the board's own result, or nothing, removes it; byes and nonsense are refused" do
      {t, [_ann, _ben, _cas, dan]} = event(2)
      {:ok, _} = Tournaments.set_rating_correction(board(t, 1, 1), "0-1")

      assert {:ok, %{rating_result: nil}} =
               Tournaments.set_rating_correction(board(t, 1, 1), "1-0")

      {:ok, _} = Tournaments.set_rating_correction(board(t, 1, 1), "0-1")
      assert {:ok, %{rating_result: nil}} = Tournaments.set_rating_correction(board(t, 1, 1), "")

      assert {:error, :invalid_result} =
               Tournaments.set_rating_correction(board(t, 1, 1), "2-0")

      assert {:error, :invalid_result} = Tournaments.set_rating_correction(board(t, 1, 1), "*W")

      round = Tournaments.get_round(t.id, 1)

      bye =
        Repo.insert!(%Board{round_id: round.id, board: 3, white_player_id: dan.id, result: "bye"})

      assert {:error, :not_a_game} = Tournaments.set_rating_correction(bye, "1-0")
    end

    test "an ordinary correction of the result drops it" do
      {t, _} = event(2)
      {:ok, _} = Tournaments.set_rating_correction(board(t, 1, 1), "0-1")

      {:ok, updated} = Tournaments.update_pairing_result(board(t, 1, 1), "1/2-1/2")
      assert updated.rating_result == nil
    end
  end

  describe "where it goes" do
    setup do
      {t, ps} = event(2)
      {:ok, _} = Tournaments.set_rating_correction(board(t, 1, 1), "0-1")
      %{t: Repo.reload!(t), ps: ps}
    end

    test "the standings and the engine's input keep the result the event used", %{t: t, ps: ps} do
      [ann, ben | _] = ps
      standings = Map.new(Standings.standings(t), &{&1.player.id, &1})
      assert standings[ann.id].points == 1.5
      assert standings[ben.id].points == 1.0

      rows = Pairing.trf_player_rows(t, Tournaments.list_players(t.id))
      assert [%{result: "1"} | _] = Enum.find(rows, &(&1.id == ann.id)).games
      assert [%{result: "0"} | _] = Enum.find(rows, &(&1.id == ben.id)).games

      {:ok, engine} = TrfExport.export(t, nil, dialect: :engine)
      assert line(engine, "Ann") =~ ~r" 2 w 1"
    end

    test "the TRF26 report has the corrected result and a ### line (Q193)", %{t: t} do
      {:ok, text} = TrfExport.export(t)
      assert line(text, "Ann") =~ ~r" 2 w 0"
      assert line(text, "Ben") =~ ~r" 1 b 1"

      assert text =~
               "### Rating correction @ Round 1: 1-2: 1-0 => 0-1 (pairings and standings used 1-0)"

      {:ok, rating} = TrfExport.export(t, nil, for: :rating)
      assert line(rating, "Ann") =~ ~r" 2 w 0"
      refute rating =~ "###"
    end

    test "a backup keeps it", %{t: t} do
      envelope =
        t |> TournamentExport.export_tournament() |> Jason.encode!() |> Jason.decode!()

      user =
        Repo.insert!(%PairingsEngine.Accounts.User{
          email: "rc#{System.unique_integer([:positive])}@example.com",
          confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
        })

      assert {:ok, [copy]} =
               TournamentImport.import(envelope, PairingsEngine.Accounts.Scope.for_user(user))

      assert [%{result: "1-0", rating_result: "0-1"}] =
               Tournaments.list_rating_corrections(copy.id)
    end
  end
end
