defmodule PairingsEngine.TrfCheckerRoundTripTest do
  @moduledoc """
  The report this app writes passes the checker FIDE's testers would run on
  it: `ainalrami -c`, the pairing and tie-break checker the VCL4THP
  submission names (Q19-Q21). Its rounds replay to the same boards, and its
  rank column follows the tie-breaks its `202` lists (Q217).

  Two defects this caught on 2026-10-02: the rank column (86-89) carried the
  starting rank, so nearly every place read as wrong; and `202` carried this
  app's spelling of four tie-breaks (BHC1 for BH/C1, ...), so the standings
  could not be checked at all.
  """
  # async: false - it pairs whole tournaments, and SQLite takes one writer.
  use PairingsEngine.DataCase, async: false

  import ExUnit.CaptureIO

  alias PairingsEngine.{Pairing, Repo, Tournaments, TrfExport, TrfImport}
  alias PairingsEngine.Tournaments.Tournament

  @results ~w(1-0 0-1 1/2-1/2 1-0 0-1)

  defp played_tournament(players, rounds, tiebreaks) do
    t =
      Repo.insert!(%Tournament{
        name: "Checker round trip",
        type: "swiss",
        rounds_count: rounds,
        tiebreaks: tiebreaks,
        round_dates: for(r <- 1..rounds, do: "2026-09-#{String.pad_leading("#{r}", 2, "0")}")
      })

    for i <- 1..players do
      {:ok, _} =
        Tournaments.create_player(t.id, %{
          tournament_id: t.id,
          name: "Player #{i}",
          fide_rating: 2400 - 37 * i
        })
    end

    for _ <- 1..rounds do
      {:ok, round} = Pairing.pair_next_round(Repo.reload!(t), [])
      round = Tournaments.get_round(t.id, round.number)

      for {p, i} <- Enum.with_index(round.pairings), p.black_player_id do
        {:ok, _} =
          Tournaments.update_pairing_result(p, Enum.at(@results, rem(i + round.number, 5)))
      end
    end

    Repo.reload!(t)
  end

  defp check(text) do
    path = Path.join(System.tmp_dir!(), "op_checker_#{System.unique_integer([:positive])}.trf")
    File.write!(path, text)

    try do
      {code, output} =
        with_io(:stderr, fn ->
          capture_io(fn -> send(self(), {:code, Ainalrami.CLI.run([path, "-c"])}) end)
          receive do: ({:code, code} -> code)
        end)

      {code, output}
    after
      File.rm(path)
    end
  end

  test "an odd field, the default Swiss tie-breaks: the checker finds nothing" do
    t = played_tournament(13, 6, ~w(BHC1 BH SB DE WIN PS))
    {:ok, text} = TrfExport.export(t)

    assert text =~ "\r\n202 BH/C1,BH,SB,DE,WIN,PS\r\n"
    assert {0, output} = check(text)
    refute output =~ "do not follow"
  end

  test "the median and the rating tie-breaks too" do
    t = played_tournament(16, 5, ~w(MBH BHC2 AROC1 SB))
    {:ok, text} = TrfExport.export(t)

    assert text =~ "\r\n202 BH/M1,BH/C2,ARO/C1,SB\r\n"
    assert {0, _output} = check(text)
  end

  test "the rank column is the place, not the starting rank" do
    t = played_tournament(10, 5, ~w(BH SB))
    {:ok, text} = TrfExport.export(t)

    places =
      t
      |> PairingsEngine.Standings.standings()
      |> Map.new(&{&1.player.pairing_number, &1.rank})

    for line <- String.split(text, "\r\n"), String.starts_with?(line, "001") do
      tpn = line |> String.slice(4, 4) |> String.trim() |> String.to_integer()
      rank = line |> String.slice(85, 4) |> String.trim() |> String.to_integer()
      assert rank == Map.fetch!(places, tpn)
    end
  end

  test "C.07's spelling reads back as this app's codes" do
    t = played_tournament(10, 3, ~w(BHC1 MBH AROC1 SB))
    {:ok, text} = TrfExport.export(t)

    {:ok, imported, _notes} = TrfImport.import_text(text, user_scope())
    assert imported.tiebreaks == ~w(BHC1 MBH AROC1 SB)
  end

  defp user_scope do
    PairingsEngine.AccountsFixtures.user_scope_fixture()
  end
end
