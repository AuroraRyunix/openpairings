defmodule PairingsEngine.PairingTest do
  use PairingsEngine.DataCase, async: true
  import Ecto.Query

  alias PairingsEngine.{Pairing, Repo, Tournaments}
  alias PairingsEngine.Tournaments.Tournament

  ## ---------- pure eligibility logic ----------

  test "eligible_players/2 excludes withdrawn, permanently-absent and forfeited players" do
    tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 5})

    active = insert_player(tournament, "Active", status: "active")
    withdrawn = insert_player(tournament, "Withdrawn", status: "withdrawn")
    absent = insert_player(tournament, "Absent", absent: true)
    forfeit = insert_player(tournament, "Forfeit", forfeit: true)

    ids = Pairing.eligible_players(tournament.id, 1) |> Enum.map(& &1.id)

    assert active.id in ids
    refute withdrawn.id in ids
    refute absent.id in ids
    refute forfeit.id in ids
  end

  test "eligible_players/2 excludes a player only for the rounds listed in absent_rounds" do
    tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 5})
    player = insert_player(tournament, "Sometimes Absent", absent_rounds: "3,5")

    assert player.id in (Pairing.eligible_players(tournament.id, 1) |> Enum.map(& &1.id))
    assert player.id in (Pairing.eligible_players(tournament.id, 2) |> Enum.map(& &1.id))
    refute player.id in (Pairing.eligible_players(tournament.id, 3) |> Enum.map(& &1.id))
    assert player.id in (Pairing.eligible_players(tournament.id, 4) |> Enum.map(& &1.id))
    refute player.id in (Pairing.eligible_players(tournament.id, 5) |> Enum.map(& &1.id))
  end

  test "absent_for_round?/2 is a pure check against the comma-separated absent_rounds list" do
    tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 5})
    player = insert_player(tournament, "P", absent_rounds: "1")

    assert Pairing.absent_for_round?(player, 1)
    refute Pairing.absent_for_round?(player, 2)

    blank = insert_player(tournament, "Q", absent_rounds: "")
    refute Pairing.absent_for_round?(blank, 1)
  end

  ## ---------- full pairing run (invokes JaVaFo) ----------

  test "pair_next_round/1 excludes a player absent for this round and gives them a requested-zero bye" do
    tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 3})

    p1 = insert_player(tournament, "Alice", fide_rating: 2000)
    p2 = insert_player(tournament, "Bob", fide_rating: 1900)
    p3 = insert_player(tournament, "Carol", fide_rating: 1800)
    absentee = insert_player(tournament, "Dave", fide_rating: 1700, absent_rounds: "1")

    assert {:ok, round} = Pairing.pair_next_round(tournament)
    round = Repo.preload(round, :pairings)

    assert round.number == 1
    # Only 1 real pairing among {Alice, Bob, Carol} — the fourth (odd) player
    # among the eligible three gets a pairing-allocated bye, so 2 pairing
    # rows total (1 game + 1 allocated bye); Dave never reaches JaVaFo.
    assert length(round.pairings) == 2

    pairing_player_ids =
      round.pairings
      |> Enum.flat_map(&[&1.white_player_id, &1.black_player_id])
      |> Enum.reject(&is_nil/1)

    refute absentee.id in pairing_player_ids
    assert p1.id in pairing_player_ids
    assert p2.id in pairing_player_ids
    assert p3.id in pairing_player_ids

    byes =
      Repo.all(
        from b in "byes",
          where: b.tournament_id == ^tournament.id and b.player_id == ^absentee.id,
          select: %{round: b.round, type: b.type}
      )

    assert byes == [%{round: 1, type: "requested-zero"}]
  end

  ## ---------- PubSub broadcasts ----------

  test "pair_next_round/1 broadcasts :rounds on the tournament topic" do
    tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 3})
    insert_player(tournament, "Alice", fide_rating: 2000)
    insert_player(tournament, "Bob", fide_rating: 1900)

    Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))

    assert {:ok, _round} = Pairing.pair_next_round(tournament)

    tid = tournament.id
    assert_receive {:tournament_changed, ^tid, :rounds}
  end

  test "pair_next_round/1 does not broadcast when pairing fails" do
    tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 3})
    insert_player(tournament, "Alice", fide_rating: 2000)

    Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))

    assert {:error, _reason} = Pairing.pair_next_round(tournament)

    refute_receive {:tournament_changed, _, :rounds}
  end

  test "delete_round/2 broadcasts :rounds on the tournament topic" do
    tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 3})
    insert_player(tournament, "Alice", fide_rating: 2000)
    insert_player(tournament, "Bob", fide_rating: 1900)

    {:ok, _round} = Pairing.pair_next_round(tournament)

    Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))

    assert :ok = Pairing.delete_round(tournament.id, 1)

    tid = tournament.id
    assert_receive {:tournament_changed, ^tid, :rounds}
  end

  ## ---------- TRF result-code mapping ----------

  test "javafo_input/2 maps every internal result string to the correct TRF16 codes" do
    tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 7})

    white = insert_player(tournament, "White", fide_rating: 2000, pairing_number: 1)
    black = insert_player(tournament, "Black", fide_rating: 1900, pairing_number: 2)

    # {internal result, expected white TRF code, expected black TRF code}
    results = [
      {"1-0", "1", "0"},
      {"0-1", "0", "1"},
      {"1/2-1/2", "=", "="},
      # Forfeits are unplayed for both sides (FIDE Art. 16), win side gets '+'.
      {"1-0FF", "+", "-"},
      {"0-1FF", "-", "+"},
      # Double forfeit: neither played, '-' for both.
      {"0-0FF", "-", "-"},
      # Played "0-0" (both lose, e.g. both defaulted after moving): '0' for both.
      {"0-0", "0", "0"}
    ]

    results
    |> Enum.with_index(1)
    |> Enum.each(fn {{result, _w, _b}, round_number} ->
      round =
        Repo.insert!(%PairingsEngine.Tournaments.Round{
          tournament_id: tournament.id,
          number: round_number,
          status: "finished"
        })

      Repo.insert!(%PairingsEngine.Tournaments.Pairing{
        round_id: round.id,
        board: 1,
        white_player_id: white.id,
        black_player_id: black.id,
        result: result
      })
    end)

    trf = Pairing.javafo_input(tournament)
    lines = String.split(trf, "\r\n")
    white_line = Enum.find(lines, &(String.starts_with?(&1, "001") and &1 =~ "White"))
    black_line = Enum.find(lines, &(String.starts_with?(&1, "001") and &1 =~ "Black"))

    results
    |> Enum.with_index(1)
    |> Enum.each(fn {{result, w_code, b_code}, round_number} ->
      # Round blocks repeat every 10 columns starting at column 92; result
      # is the 8th char of the block (opponent id 4, colour 1, result 1,
      # with 1-char gaps — see PairingsEngine.Trf's round_cols/1).
      result_col = 92 + (round_number - 1) * 10 + 7

      assert String.at(white_line, result_col - 1) == w_code,
             "round #{round_number} (#{result}): expected white code #{w_code}"

      assert String.at(black_line, result_col - 1) == b_code,
             "round #{round_number} (#{result}): expected black code #{b_code}"
    end)
  end

  ## ---------- helpers ----------

  defp insert_player(tournament, name, attrs) do
    defaults = %{tournament_id: tournament.id, name: name}
    {:ok, player} = Tournaments.create_player(tournament.id, Map.merge(defaults, Map.new(attrs)))
    player
  end
end
