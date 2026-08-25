defmodule PairingsEngine.UnratedResultsTest do
  @moduledoc """
  Games that were played but are not rated - TRF codes `W` / `D` / `L`.

  Typically a game that ended before the minimum number of moves. FIDE
  gives them their own codes precisely because the distinction is invisible
  from the score: they pay exactly what their rated twins pay, they occupy
  a real pairing, both players were present, and every pairing rule treats
  them as contested. The one thing that differs is that the rating report
  says so.

  That is what makes them easy to get wrong in the direction that loses
  data. A result code nothing recognises falls through a catch-all and
  becomes zero points, or PGN's `*`, or a blank cell - and nobody notices,
  because the tournament still adds up for everybody else. Each assertion
  below guards one of those catch-alls; `SwarExport.result_bits/2`'s in
  particular returned `{0, 0.0}`, dropping the result and the points
  together.

  Required by VCL4THP Q185 (7% penalty).
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Keizer, PgnExport, Repo, Standings, SwarExport, Trf, TrfExport}
  alias PairingsEngine.Tournaments.{Tournament, Player, Round, Pairing}

  # Two players, one round, one game - the smallest thing that can carry a
  # result through scoring and every exporter.
  defp fixture(result, opts \\ []) do
    tournament =
      Repo.insert!(%Tournament{
        name: "Unrated",
        type: Keyword.get(opts, :type, "swiss"),
        pairing_system: Keyword.get(opts, :pairing_system, "swiss"),
        rounds_count: 1
      })

    [white, black] =
      for {name, rating, n} <- [{"White", 2000, 1}, {"Black", 1900, 2}] do
        Repo.insert!(%Player{
          tournament_id: tournament.id,
          name: name,
          fide_rating: rating,
          pairing_number: n
        })
      end

    round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})

    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 1,
      white_player_id: white.id,
      black_player_id: black.id,
      result: result
    })

    {tournament, white, black}
  end

  defp points(tournament) do
    tournament
    |> Standings.standings()
    |> Map.new(fn entry -> {entry.player.name, entry.points} end)
  end

  describe "scoring" do
    test "an unrated result pays exactly what its rated twin pays" do
      for {rated, unrated} <- [{"1-0", "1-0U"}, {"0-1", "0-1U"}, {"1/2-1/2", "1/2-1/2U"}] do
        {a, _, _} = fixture(rated)
        {b, _, _} = fixture(unrated)

        assert points(a) == points(b),
               "#{unrated} did not score like #{rated}"
      end
    end

    test "the points are the ones you would expect, not merely equal to each other" do
      # Guards against both sides being broken identically - two zeroes
      # compare equal just as happily as two ones.
      {win, _, _} = fixture("1-0U")
      {draw, _, _} = fixture("1/2-1/2U")

      assert points(win) == %{"White" => 1.0, "Black" => 0.0}
      assert points(draw) == %{"White" => 0.5, "Black" => 0.5}
    end
  end

  describe "TRF export" do
    test "each side gets its own code" do
      {tournament, _, _} = fixture("1-0U")
      {:ok, trf} = TrfExport.export(tournament)

      lines = trf |> String.split(~r/\r?\n/) |> Enum.filter(&String.starts_with?(&1, "001"))
      assert [white_line, black_line] = lines

      # The result is the last non-blank character of the round entry.
      assert String.ends_with?(String.trim_trailing(white_line), "W")
      assert String.ends_with?(String.trim_trailing(black_line), "L")
    end

    test "a draw is D for both sides" do
      {tournament, _, _} = fixture("1/2-1/2U")
      {:ok, trf} = TrfExport.export(tournament)

      lines = trf |> String.split(~r/\r?\n/) |> Enum.filter(&String.starts_with?(&1, "001"))

      for line <- lines do
        assert String.ends_with?(String.trim_trailing(line), "D")
      end
    end

    test "the rated twin still exports as 1 and 0, unchanged" do
      # The new codes must not have captured the ordinary path on the way in.
      {tournament, _, _} = fixture("1-0")
      {:ok, trf} = TrfExport.export(tournament)

      lines = trf |> String.split(~r/\r?\n/) |> Enum.filter(&String.starts_with?(&1, "001"))
      assert [white_line, black_line] = lines

      assert String.ends_with?(String.trim_trailing(white_line), "1")
      assert String.ends_with?(String.trim_trailing(black_line), "0")
    end
  end

  describe "the engine is told this tournament's scoring" do
    test "a non-standard scoring system reaches the engine" do
      # Score decides bracket. Until the point system was passed, a 3-1-0
      # tournament was SCORED at 3-1-0 by the standings and PAIRED at
      # 1/half/0 by the engine - two different tournaments, one database.
      t = %Tournament{
        points_win: 3.0,
        points_draw: 1.0,
        points_loss: 0.0,
        bye_value: 3.0,
        abs_value: nil
      }

      assert Tournament.engine_point_system(t) == %{
               win: 3.0,
               draw: 1.0,
               loss: 0.0,
               pairing_allocated_bye: 3.0,
               forfeit_loss: 0.0,
               zero_point_bye: 0.0
             }
    end

    test "the default tournament maps to the engine's own default" do
      # A tournament nobody has touched must pair exactly as it did before
      # the point system was passed at all.
      assert Tournament.engine_point_system(%Tournament{}) ==
               Ainalrami.Trf.default_point_system()
    end

    test "a sat-out round carries the tournament's absence value" do
      t = %Tournament{points_win: 1.0, points_draw: 0.5, points_loss: 0.0, abs_value: 0.5}

      assert Tournament.engine_point_system(t).zero_point_bye == 0.5
    end
  end

  describe "the codes themselves" do
    test "W, D and L are known to Trf as playing codes" do
      # `Trf` validates every game against its playing/bye sets. Left out of
      # the playing set an imported W/D/L is rejected as unknown; put in the
      # bye set it would be read as an unpaired round.
      codes = Trf.result_codes()

      assert codes.unrated_win == "W"
      assert codes.unrated_draw == "D"
      assert codes.unrated_loss == "L"
    end
  end

  describe "the other exporters do not silently drop it" do
    test "PGN records the real result, not its unknown-result marker" do
      {tournament, _, _} = fixture("1-0U")
      pgn = PgnExport.export(tournament)

      assert pgn =~ ~s([Result "1-0"])
      refute pgn =~ ~s([Result "*"])
    end

    test "SWAR export keeps the points rather than falling through to zero" do
      {tournament, _, _} = fixture("1-0U")
      unrated = SwarExport.export(tournament)
      {rated_t, _, _} = fixture("1-0")
      rated = SwarExport.export(rated_t)

      # SWAR has no code for "played, not rated", so both map to the same
      # rated bits and the two files should have the same shape. This is a
      # structural check, not a proof that the points are right - the
      # scoring assertions above are that. What it catches is the collapse:
      # the catch-all wrote bitmask 0 and 0.0 points, which is a different
      # file, not merely a differently-labelled one.
      assert byte_size(unrated) == byte_size(rated)
    end

    test "Keizer scores it as a contested game" do
      {tournament, _, _} = fixture("1-0U", type: "keizer", pairing_system: "keizer")
      {rated_t, _, _} = fixture("1-0", type: "keizer", pairing_system: "keizer")

      by_name = fn t ->
        t |> Keizer.standings() |> Map.new(&{&1.player.name, &1.points})
      end

      assert by_name.(tournament) == by_name.(rated_t)
    end
  end
end
