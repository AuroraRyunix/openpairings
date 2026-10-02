defmodule PairingsEngine.FideModeLocksTest do
  @moduledoc """
  What FIDE mode stops, and the one way out of it - the VCL4THP v13
  questions a tournament in FIDE mode must answer "no" to:

    * scoring a game cannot give is a departure (Q74, Q81, Q83);
    * once round 1 is paired, the number of rounds, the scoring, the bye's
      value, the acceleration, the pairing system and the tie-breaks cannot
      change, and there is no Unlock for them (Q57, Q75, Q85, Q93, Q109,
      Q110, Q200);
    * only the round before the last one played, and later ones, can be
      changed (Q189-Q191), the result of a postponed game excepted (Q162);
    * leaving FIDE mode is one deliberate act, for good, and the TRF says
      from which round (Q44, Q45).

  The round-1 lock and its Unlock, which still hold outside FIDE mode, are
  `settings_lock_test.exs`.
  """
  # async: false - it pairs many rounds, and SQLite takes one writer.
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Compliance, Pairing, Repo, Tournaments, TrfExport}
  alias PairingsEngine.Tournaments.{Round, Tournament}

  defp tournament(attrs \\ []) do
    t =
      Repo.insert!(
        struct(
          Tournament,
          Map.merge(
            %{
              name: "FIDE mode",
              type: "swiss",
              rounds_count: 5,
              tiebreaks: ~w(BH SB),
              round_dates: ~w(2026-09-01 2026-09-08 2026-09-15 2026-09-22 2026-09-29)
            },
            Map.new(attrs)
          )
        )
      )

    players =
      for {name, i} <- Enum.with_index(~w(Ann Ben Cas Dan Eva Fay Gus Hal Ida Jan)) do
        rating = 2000 - 50 * i

        {:ok, p} =
          Tournaments.create_player(t.id, %{tournament_id: t.id, name: name, fide_rating: rating})

        p
      end

    {Repo.reload!(t), players}
  end

  # Pairs the next round and gives every board a result, so it is played.
  defp play_round!(t) do
    {:ok, round} =
      Pairing.pair_next_round(Repo.reload!(t), acknowledged: [:adjourned_older_round_open])

    round = Tournaments.get_round(t.id, round.number)

    for {p, i} <- Enum.with_index(round.pairings), p.black_player_id do
      {:ok, _} = Tournaments.update_pairing_result(p, Enum.at(~w(1-0 0-1 1/2-1/2), rem(i, 3)))
    end

    Tournaments.get_round(t.id, round.number)
  end

  defp game(round), do: Enum.find(round.pairings, & &1.black_player_id)

  defp codes(t), do: t |> Compliance.check() |> Enum.map(& &1.code)

  ## -------------------------------------------------------------------------

  describe "scoring a game cannot give takes a tournament out of FIDE mode" do
    test "two draws worth more than a win and a loss (Q74)" do
      {t, _} = tournament()
      {:ok, t} = Tournaments.update_tournament(t, %{"points_draw" => "0.75"})

      assert :draws_outscore_win in codes(t)
      assert t.fide_compliance_lost_round == 0
      refute Compliance.fide_mode?(t)
    end

    test "a bye worth more than a win (Q81), and with 1-1/2-0 one no game gives (Q83)" do
      {t, _} = tournament()
      {:ok, t} = Tournaments.update_tournament(t, %{"bye_value" => "1.5"})
      assert Enum.sort(codes(t)) == [:bye_above_win, :bye_not_a_game_score]

      {t2, _} = tournament()
      {:ok, t2} = Tournaments.update_tournament(t2, %{"bye_value" => "0.25"})
      assert codes(t2) == [:bye_not_a_game_score]
    end

    test "what FIDE allows stays in: 3-1-0, a bye of 2 under it (Q84), a bye of a draw or nothing" do
      for attrs <- [
            %{
              "points_win" => "3",
              "points_draw" => "1",
              "points_loss" => "0",
              "bye_value" => "2"
            },
            %{"bye_value" => "0.5"},
            %{"bye_value" => "0"}
          ] do
        {t, _} = tournament()
        {:ok, t} = Tournaments.update_tournament(t, attrs)
        assert Compliance.check(t) == [], "#{inspect(attrs)} should stay in FIDE mode"
        assert Compliance.fide_mode?(t)
      end
    end

    test "a Keizer ladder is not judged on its scoring as well" do
      t = %Tournament{pairing_system: "keizer", points_draw: 0.75, bye_value: 2.0}
      assert codes(t) == [:non_fide_pairing_system]
    end
  end

  describe "fide_mode?/1" do
    test "is a new tournament's state, and lost for good" do
      {t, _} = tournament()
      assert Compliance.fide_mode?(t)

      {:ok, t} = Tournaments.update_tournament(t, %{"pairing_system" => "keizer"})
      refute Compliance.fide_mode?(t)

      # The setting put back does not bring it back (Q45).
      {:ok, t} = Tournaments.update_tournament(t, %{"pairing_system" => "swiss"})
      assert Compliance.compliant?(t)
      refute Compliance.fide_mode?(t)
    end
  end

  describe "once round 1 is paired, FIDE mode freezes the event's terms" do
    test "each of them is refused, and Unlock does not open it" do
      {t, _} = tournament()
      play_round!(t)
      t = Repo.reload!(t)

      for {field, value} <- [
            {"rounds_count", "7"},
            {"points_win", "3"},
            {"points_draw", "1"},
            {"points_loss", "0.5"},
            {"bye_value", "0.5"},
            {"acceleration", "baku"},
            {"pairing_system", "round_robin"},
            {"tiebreaks", ~w(SB BH)}
          ] do
        atom = String.to_existing_atom(field)
        assert atom in Tournaments.fide_locked_fields(t)
        assert atom in Tournaments.locked_fields(t)

        assert Tournaments.update_tournament(t, %{field => value}, unlock: [atom]) ==
                 {:error, :locked_in_fide_mode},
               "#{field} changed in FIDE mode after round 1"
      end

      assert Repo.reload!(t).rounds_count == 5
    end

    test "the same value round-tripped by a form is not a change" do
      {t, _} = tournament()
      play_round!(t)
      t = Repo.reload!(t)

      assert {:ok, _} =
               Tournaments.update_tournament(t, %{
                 "rounds_count" => "5",
                 "tiebreaks" => ~w(BH SB),
                 "venue" => "Town Hall"
               })
    end

    test "before round 1 everything is free" do
      {t, _} = tournament()
      assert Tournaments.fide_locked_fields(t) == []
      assert {:ok, t} = Tournaments.update_tournament(t, %{"rounds_count" => "7"})
      assert t.rounds_count == 7
    end

    test "outside FIDE mode the old round-1 lock is all there is" do
      {t, _} = tournament(fide_compliance_lost_round: 0)
      play_round!(t)
      t = Repo.reload!(t)

      assert Tournaments.fide_locked_fields(t) == []
      assert {:ok, t} = Tournaments.update_tournament(t, %{"rounds_count" => "7"})
      assert t.rounds_count == 7

      assert {:ok, t} =
               Tournaments.update_tournament(t, %{"pairing_system" => "round_robin"},
                 unlock: [:pairing_system]
               )

      assert t.pairing_system == "round_robin"
    end

    test "a round robin's cycles freeze with round 1; its derived round count is the program's" do
      {t, _} = tournament(pairing_system: "round_robin", rr_cycles: 1)
      {:ok, _} = Pairing.pair_next_round(Repo.reload!(t), [])
      t = Repo.reload!(t)

      assert :rr_cycles in Tournaments.fide_locked_fields(t)
      refute :rounds_count in Tournaments.fide_locked_fields(t)

      assert Tournaments.update_tournament(t, %{"rr_cycles" => "2"}, unlock: [:rr_cycles]) ==
               {:error, :locked_in_fide_mode}
    end
  end

  describe "leave_fide_mode/1" do
    test "records the round under way, opens the locks, and cannot be undone" do
      {t, _} = tournament()
      play_round!(t)
      play_round!(t)
      t = Repo.reload!(t)

      assert {:ok, left} = Tournaments.leave_fide_mode(t)
      assert left.fide_compliance_lost_round == 2
      refute Compliance.fide_mode?(left)
      assert Tournaments.fide_locked_fields(left) == []
      assert {:ok, _} = Tournaments.update_tournament(left, %{"rounds_count" => "7"})

      assert Tournaments.leave_fide_mode(Repo.reload!(t)) == {:error, :not_in_fide_mode}
    end

    test "is refused on an archived tournament" do
      {t, _} = tournament()

      t =
        t
        |> Ecto.Changeset.change(archived_at: DateTime.truncate(DateTime.utc_now(), :second))
        |> Repo.update!()

      assert Tournaments.leave_fide_mode(t) == {:error, :archived}
    end
  end

  describe "the TRF says the tournament left FIDE mode, and from which round (Q44)" do
    test "a ### line after the header, in the FIDE dialect only" do
      {t, _} = tournament()
      play_round!(t)
      play_round!(t)

      {:ok, before} = TrfExport.export(Repo.reload!(t))
      refute before =~ "FIDE mode exited"

      {:ok, _} = Tournaments.leave_fide_mode(Repo.reload!(t))
      t = Repo.reload!(t)

      {:ok, text} = TrfExport.export(t)
      assert text =~ "\r\n### FIDE mode exited @ Round 2\r\n"
      assert Ainalrami.Trf.parse(text).players |> length() == 10

      {:ok, engine} = TrfExport.export(t, nil, dialect: :engine)
      refute engine =~ "###"
    end

    test "round 0 is said in words" do
      {t, _} = tournament(fide_compliance_lost_round: 0)
      play_round!(t)

      {:ok, text} = TrfExport.export(Repo.reload!(t))
      assert text =~ "### FIDE mode exited before Round 1 was paired"
    end
  end

  describe "only the last two rounds played can be changed (C.04.2:4.3)" do
    setup do
      {t, players} = tournament()
      rounds = for _ <- 1..4, do: play_round!(t)
      %{t: Repo.reload!(t), rounds: rounds, players: players}
    end

    test "the window is from the round before the last one played", %{t: t, rounds: rounds} do
      assert Tournaments.last_played_round(t.id) == 4
      [r1, r2, r3, r4] = rounds

      for r <- [r1, r2] do
        assert Tournaments.update_pairing_result(game(r), "0-1") ==
                 {:error, :round_closed_in_fide_mode},
               "round #{r.number} still open"
      end

      for r <- [r3, r4], do: assert({:ok, _} = Tournaments.update_pairing_result(game(r), "0-1"))
    end

    test "a round in progress keeps the one before the last played open", %{t: t} do
      {:ok, r5} = Pairing.pair_next_round(Repo.reload!(t), [])
      assert Tournaments.last_played_round(t.id) == 4
      assert Tournaments.ensure_round_editable(t, 3) == :ok
      assert Tournaments.ensure_round_editable(t, r5.number) == :ok
      assert Tournaments.ensure_round_editable(t, 2) == {:error, :round_closed_in_fide_mode}
    end

    test "hand edits of a closed round are refused too", %{t: t, rounds: [r1 | _]} do
      board = game(r1)
      round = Repo.preload(Repo.get!(Round, r1.id), :pairings)

      assert Tournaments.swap_players_in_round(
               round,
               board.white_player_id,
               board.black_player_id
             ) == {:error, :round_closed_in_fide_mode}

      assert Tournaments.ensure_round_editable(t.id, 1) == {:error, :round_closed_in_fide_mode}
    end

    test "a player who played a closed round is withdrawn, not deleted", %{players: [ann | _]} do
      assert Tournaments.delete_player(ann) == {:error, :player_in_closed_round}
    end

    test "outside FIDE mode every round stays open", %{t: t, rounds: [r1 | _]} do
      {:ok, _} = Tournaments.leave_fide_mode(t)
      assert {:ok, _} = Tournaments.update_pairing_result(game(r1), "0-1")
    end
  end

  describe "a postponed game's result is enterable at any time (Q162)" do
    test "even when its round has closed" do
      {t, _} = tournament(postponed_games: true)
      r1 = play_round!(t)
      {:ok, postponed} = Tournaments.update_pairing_result(game(r1), "*")
      for _ <- 2..4, do: play_round!(t)

      assert Tournaments.last_played_round(t.id) == 4
      assert {:ok, played} = Tournaments.update_pairing_result(postponed, "1/2-1/2")
      assert played.result == "1/2-1/2"

      # And corrected later, like any other entry of that game.
      assert {:ok, _} =
               Tournaments.update_pairing_result(played, "1-0",
                 acknowledged: [:adjourned_non_draw_result]
               )
    end
  end
end
