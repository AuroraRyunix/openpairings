defmodule PairingsEngine.PostponedFideModeTest do
  @moduledoc """
  VCL4THP Q169: in FIDE mode no TRF and no final standings while a postponed
  game has no result. The ways on are the result itself, or recording the
  game as not played in this event - a departure that leaves FIDE mode, is
  stamped, and is written as a `###` line in the TRF26 report. The later
  postponed-games file is untouched by any of it.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Compliance, Pairing, PostponedGames, Repo, TrfExport, Tournaments}
  alias PairingsEngine.Tournaments.Tournament

  defp tournament(attrs \\ []) do
    t =
      Repo.insert!(
        struct(
          Tournament,
          Map.merge(
            %{
              name: "Club championship",
              type: "swiss",
              rounds_count: 2,
              tiebreaks: ~w(BH SB),
              postponed_games: true,
              round_dates: ["2026-09-01", "2026-09-08"]
            },
            Map.new(attrs)
          )
        )
      )

    players =
      for {name, rating} <- [{"Alice", 2000}, {"Bob", 1900}, {"Carol", 1800}, {"Dave", 1700}],
          into: %{} do
        {:ok, p} =
          Tournaments.create_player(t.id, %{tournament_id: t.id, name: name, fide_rating: rating})

        {name, p}
      end

    {t, players}
  end

  defp pair!(t) do
    {:ok, round} = Pairing.pair_next_round(Repo.reload!(t))
    Tournaments.get_round(t.id, round.number)
  end

  defp board_of(round, player),
    do: Enum.find(round.pairings, &(player.id in [&1.white_player_id, &1.black_player_id]))

  defp result!(pairing, result, opts \\ []) do
    {:ok, updated} = Tournaments.update_pairing_result(pairing, result, opts)
    updated
  end

  defp others!(round, except),
    do: for(p <- round.pairings, p.id != except.id, p.black_player_id, do: result!(p, "1-0"))

  # Round 1 with one game postponed, the rest played.
  defp with_open_game do
    {t, %{"Alice" => alice}} = tournament()
    round1 = pair!(t)
    postponed = round1 |> board_of(alice) |> result!("*W")
    others!(round1, postponed)
    {Repo.reload!(t), postponed}
  end

  describe "in FIDE mode, an open postponed game" do
    test "refuses every TRF - copy, engine spelling, file for rating - and names the game" do
      {t, postponed} = with_open_game()
      assert Compliance.fide_mode?(t)

      for opts <- [[], [copy: true], [dialect: :engine], [for: :rating]] do
        assert {:error, {:open_postponed, [%{round: 1, pairing: %{id: id}}]}} =
                 TrfExport.export(t, [1], opts)

        assert id == postponed.id
      end
    end

    # Only a file that holds the open game's round is refused: the copy of
    # an earlier round (the rating inbox's, of a round sent last week) says
    # nothing about a game that had not been paired yet.
    test "a file of only the rounds before its round is made; one that includes it is not" do
      {t, %{"Alice" => alice}} = tournament()
      round1 = pair!(t)
      for p <- round1.pairings, p.black_player_id, do: result!(p, "1-0")

      round2 = pair!(t)
      postponed = round2 |> board_of(alice) |> result!("*W")
      others!(round2, postponed)
      t = Repo.reload!(t)
      assert Compliance.fide_mode?(t)

      for opts <- [[], [copy: true], [dialect: :engine], [for: :rating]] do
        assert {:ok, _text} = TrfExport.export(t, [1], opts)
        assert {:ok, _text} = TrfExport.export(t, "1", opts)

        for spec <- [[1, 2], [2], "1-2", nil] do
          assert {:error, {:open_postponed, [%{round: 2, pairing: %{id: id}}]}} =
                   TrfExport.export(t, spec, opts)

          assert id == postponed.id
        end
      end

      assert {:ok, %{file: _}} =
               PostponedGames.send_rounds(t, [1], &TrfExport.export(&1, [1], for: :rating))

      assert PostponedGames.sent_rounds(Repo.reload!(t)) == [1]
    end

    test "refuses sending, and marks nothing" do
      {t, _postponed} = with_open_game()

      assert {:error, {:open_postponed, [_]}} =
               PostponedGames.send_rounds(t, [1], &TrfExport.export(&1, [1], for: :rating))

      assert PostponedGames.sent_rounds(t) == []
    end

    test "refuses the final standings, but not standings after an earlier round" do
      {t, _postponed} = with_open_game()

      # One round of two: not the final standings yet.
      refute PostponedGames.final_standings_refused?(t)

      round2 = pair!(t)
      for p <- round2.pairings, p.black_player_id, do: result!(p, "1-0")
      t = Repo.reload!(t)

      assert PostponedGames.final_standings_refused?(t)
      assert PostponedGames.final_standings_refused?(t, 2)
      refute PostponedGames.final_standings_refused?(t, 1)
    end

    test "a real result for it keeps FIDE mode, and the TRF goes out" do
      {t, postponed} = with_open_game()
      result!(postponed, "1/2-1/2")
      t = Repo.reload!(t)

      assert Compliance.fide_mode?(t)
      assert PostponedGames.blocking_games(t) == []
      assert {:ok, _text} = TrfExport.export(t, [1])
    end
  end

  describe "recording it as not played in this event" do
    test "leaves FIDE mode, stamped in the round under way, and keeps the game postponed" do
      {t, postponed} = with_open_game()

      assert {:ok, %{left_fide_mode: true, pairing: pairing}} =
               PostponedGames.report_not_played(t, postponed.id)

      assert %DateTime{} = pairing.not_played_at
      assert pairing.result == "*W"

      t = Repo.reload!(t)
      assert t.fide_compliance_lost_round == 1
      refute Compliance.fide_mode?(t)

      # Again: idempotent, and no second departure.
      assert {:ok, %{left_fide_mode: false}} = PostponedGames.report_not_played(t, postponed.id)
    end

    test "the rating file writes it as not played; the TRF26 copy names it in a ### line" do
      {t, postponed} = with_open_game()
      {:ok, _} = PostponedGames.report_not_played(t, postponed.id)
      t = Repo.reload!(t)

      {:ok, rating} = TrfExport.export(t, [1], for: :rating)
      assert rating =~ "0000 - Z"
      refute rating =~ "###"

      {:ok, copy} = TrfExport.export(t, [1], copy: true)
      tpn = Map.new(Tournaments.list_players(t.id), &{&1.id, &1.pairing_number})
      pair = "#{tpn[postponed.white_player_id]}-#{tpn[postponed.black_player_id]}"

      assert copy =~
               "### Not played @ Round 1: #{pair} (postponed, reported as not played in this event)"

      assert copy =~ "### FIDE mode exited @ Round 1"
    end

    test "the round can then be sent, and a game played later still goes in the postponed-games file" do
      {t, postponed} = with_open_game()
      {:ok, _} = PostponedGames.report_not_played(t, postponed.id)

      assert {:ok, %{file: file}} =
               PostponedGames.send_rounds(
                 Repo.reload!(t),
                 [1],
                 &TrfExport.export(&1, [1], for: :rating)
               )

      assert file =~ "0000 - Z"
      assert Repo.reload!(postponed).finalised_open

      result!(Repo.reload!(postponed), "1-0",
        acknowledged: [:adjourned_non_draw_result, :finalised_result_changed]
      )

      {:ok, _} = Tournaments.set_played_on(Repo.reload!(postponed), ~D[2026-09-20])
      assert [%{pairing: %{id: id}}] = PostponedGames.sendable_late_games(Repo.reload!(t))
      assert id == postponed.id
    end

    test "only an open postponed game can be recorded" do
      {t, postponed} = with_open_game()
      played = Enum.find(Tournaments.get_round(t.id, 1).pairings, &(&1.id != postponed.id))

      assert {:error, :not_open} = PostponedGames.report_not_played(t, played.id)
      assert {:error, :not_found} = PostponedGames.report_not_played(t, -1)
      assert Compliance.fide_mode?(Repo.reload!(t))
    end

    test "outside FIDE mode it records and departs from nothing" do
      {t, postponed} = with_open_game()
      {:ok, t} = Tournaments.leave_fide_mode(t)

      # Outside FIDE mode the TRF was never refused.
      assert {:ok, _} = TrfExport.export(t, [1])

      assert {:ok, %{left_fide_mode: false}} = PostponedGames.report_not_played(t, postponed.id)
    end
  end
end
