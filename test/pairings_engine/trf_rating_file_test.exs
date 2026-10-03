defmodule PairingsEngine.TrfRatingFileTest do
  @moduledoc """
  The file SENT FOR RATING (`TrfExport.export/3` with `for: :rating`, and
  the postponed-games file sent with `PostponedGames.send_late_games/3`):

    * only real records, as SWAR's accepted FIDE files - no column ruler, no
      `DDD` legend, no comment line (`###`);
    * no unknown result: a postponed game whose result is not known is not
      played in it, `0000 - Z` for both players, worth zero, and there is no
      `?` and no `X` in a `162`; the game is rated once, in the
      postponed-games file, after it is played.

  Every other file - a copy, the engine's input - is unchanged.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Pairing, PostponedGames, Repo, TrfExport, Tournaments}
  alias PairingsEngine.Tournaments.Tournament

  defp tournament(names, attrs \\ []) do
    t =
      Repo.insert!(
        struct(
          Tournament,
          Map.merge(
            %{
              name: "Club championship",
              type: "swiss",
              rounds_count: 3,
              tiebreaks: ~w(BH SB),
              postponed_games: true,
              round_dates: ["2026-09-01", "2026-09-08", "2026-09-15"]
            },
            Map.new(attrs)
          )
        )
      )

    players =
      for {name, i} <- Enum.with_index(names), into: %{} do
        {:ok, p} =
          Tournaments.create_player(t.id, %{
            tournament_id: t.id,
            name: name,
            fide_rating: 2100 - 100 * i,
            fide_id: 20_000_000 + i
          })

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
    {:ok, updated} =
      Tournaments.update_pairing_result(
        pairing,
        result,
        [acknowledged: PostponedGames.acknowledgement_ids()] ++ opts
      )

    updated
  end

  defp rank_of(t, player_id),
    do: Enum.find(Tournaments.list_players(t.id), &(&1.id == player_id)).pairing_number

  defp send!(t, rounds) do
    {:ok, %{file: text}} =
      PostponedGames.send_rounds(
        Repo.reload!(t),
        rounds,
        &TrfExport.export(&1, rounds, for: :rating)
      )

    text
  end

  defp lines(text), do: String.split(text, "\r\n")

  defp line_of(text, rank) do
    Enum.find(lines(text), fn line ->
      String.starts_with?(line, "001") and
        line |> String.slice(4, 4) |> String.trim() == Integer.to_string(rank)
    end)
  end

  # Round `r`'s ten columns (92-101), trailing blanks dropped.
  defp block(line, r), do: line |> String.slice(91 + (r - 1) * 10, 10) |> String.trim_trailing()
  defp points(line), do: line |> String.slice(80, 4) |> String.trim() |> String.to_float()
  defp place(line), do: line |> String.slice(85, 4) |> String.trim() |> String.to_integer()

  # Nothing but records: no ruler, no legend, no comment, no unknown result.
  defp assert_only_records(text) do
    for line <- lines(text), line != "" do
      assert line =~ ~r/^\d{3}( |$)/, "not a record: #{inspect(line)}"
    end

    refute text =~ "###"
    refute text =~ "DDD"
    refute Enum.any?(lines(text), &String.starts_with?(&1, "162"))
    refute Enum.any?(lines(text), &(String.starts_with?(&1, "001") and &1 =~ "?"))
  end

  describe "a postponed game whose result is not known" do
    setup do
      # The player who postponed counts it as a win in the standings: the
      # file must still count it as nothing.
      {t, players} =
        tournament(~w(Alice Bob Carol Dave),
          postponed_requester_outcome: "win",
          postponed_opponent_outcome: "draw"
        )

      round1 = pair!(t)
      postponed = round1 |> board_of(players["Alice"]) |> result!("*W")
      [other] = Enum.reject(round1.pairings, &(&1.id == postponed.id))
      other = result!(other, "1-0")

      %{t: t, postponed: postponed, other: other}
    end

    test "is not played in the file sent for rating, for both players", ctx do
      %{t: t, postponed: postponed, other: other} = ctx
      text = send!(ctx.t, [1])

      assert_only_records(text)

      for id <- [postponed.white_player_id, postponed.black_player_id] do
        line = line_of(text, rank_of(t, id))
        assert block(line, 1) == "0000 - Z"
        assert points(line) == 0.0
      end

      winner = line_of(text, rank_of(t, other.white_player_id))
      loser = line_of(text, rank_of(t, other.black_player_id))
      assert block(winner, 1) =~ ~r/^\s*\d+ w 1$/
      assert block(loser, 1) =~ ~r/^\s*\d+ b 0$/
      assert points(winner) == 1.0

      # The places follow the file's own points, not the standings' (which
      # give the postponing player a provisional win).
      ranked =
        for p <- Tournaments.list_players(t.id) do
          line = line_of(text, p.pairing_number)
          {place(line), points(line)}
        end
        |> Enum.sort()

      assert Enum.map(ranked, &elem(&1, 0)) == [1, 2, 3, 4]
      assert hd(ranked) == {1, 1.0}
      assert Enum.map(ranked, &elem(&1, 1)) == Enum.sort(Enum.map(ranked, &elem(&1, 1)), :desc)

      # Recorded as sent unplayed: its result goes in the postponed-games file.
      assert Repo.reload!(postponed).finalised_open
    end

    test "is rated exactly once: in the postponed-games file, once played", ctx do
      %{t: t, postponed: postponed} = ctx
      report = send!(t, [1])

      result!(Repo.reload!(postponed), "0-1", played_on: ~D[2026-09-20])

      # Still not played in any later main file for rating that holds round 1.
      {:ok, all} = TrfExport.export(Repo.reload!(t), [1], for: :rating)
      assert_only_records(all)

      for text <- [report, all],
          id <- [postponed.white_player_id, postponed.black_player_id] do
        assert text |> line_of(rank_of(t, id)) |> block(1) == "0000 - Z"
      end

      {:ok, late, [_game], _receipt} =
        PostponedGames.send_late_games(Repo.reload!(t), &TrfExport.postponed_export(&1, []))

      assert_only_records(late)
      white = rank_of(t, postponed.white_player_id)
      black = rank_of(t, postponed.black_player_id)
      assert late |> line_of(white) |> block(1) =~ ~r/^\s*#{black} w 0$/
      assert late |> line_of(black) |> block(1) =~ ~r/^\s*#{white} b 1$/

      # And never again.
      assert {:error, :nothing_to_send} =
               PostponedGames.send_late_games(
                 Repo.reload!(t),
                 &TrfExport.postponed_export(&1, [])
               )
    end

    test "every other file is unchanged: the copy keeps ?, X and its marks", ctx do
      %{t: t, postponed: postponed} = ctx

      {:ok, copy} = TrfExport.export(Repo.reload!(t), [1], copy: true)
      line = line_of(copy, rank_of(t, postponed.white_player_id))
      assert String.at(line, 98) == "?"
      assert copy =~ ~r/\r\n162 .*X\s+0\.5/
      assert copy =~ "### COPY - NOT FOR RATING"
      assert copy =~ "DDD"

      # The engine dialect still writes the draw the engine paired with.
      {:ok, engine} = TrfExport.export(Repo.reload!(t), [1], dialect: :engine)
      assert engine |> line_of(rank_of(t, postponed.white_player_id)) |> String.at(98) == "="
    end
  end

  test "the other results are written as before" do
    {t, players} = tournament(~w(Alice Bob Carol Dave Erin Frank))
    round1 = pair!(t)

    [a, b, c] =
      for name <- ~w(Alice Bob Carol), do: board_of(round1, players[name])

    a = result!(a, "0-0")
    b = result!(b, "1/2-0")
    c = result!(c, "0-0FF")

    text = send!(t, [1])
    assert_only_records(text)

    code = fn id -> text |> line_of(rank_of(t, id)) |> block(1) |> String.last() end

    assert {code.(a.white_player_id), code.(a.black_player_id)} == {"0", "0"}
    assert {code.(b.white_player_id), code.(b.black_player_id)} == {"=", "0"}
    assert {code.(c.white_player_id), code.(c.black_player_id)} == {"-", "-"}
  end

  test "leaving FIDE mode is not a comment line in the file for rating" do
    {t, players} = tournament(~w(Alice Bob Carol Dave), fide_compliance_lost_round: 0)
    round1 = pair!(t)
    for p <- round1.pairings, do: result!(p, "1-0")
    _ = players

    {:ok, copy} = TrfExport.export(Repo.reload!(t), [1], copy: true)
    assert copy =~ "### FIDE mode exited before Round 1 was paired"

    assert_only_records(send!(t, [1]))
  end
end
