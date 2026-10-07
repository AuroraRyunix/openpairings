defmodule PairingsEngine.TrfImportAdjustmentsTest do
  # VCL4THP items 48, 50, 52, 55 and the import part of 112/115: a TRF
  # import reports the version it read and EVERY adjustment it made, its
  # review is a dry run, and the rounds that broke a pairing rule are kept
  # with the tournament as an Import PIBE and written to its report as `###`.
  #
  # async: false - whole-tournament writes in a real transaction, and one
  # test sets an application-environment hook.
  use PairingsEngine.DataCase, async: false

  alias Ainalrami.Trf
  alias PairingsEngine.{Repo, TrfExport, TrfImport}
  alias PairingsEngine.Tournaments.Tournament

  defp game(opponent, colour, result),
    do: %{opponent_rank: opponent, colour: colour, result: result}

  defp nobody(result), do: %{opponent_rank: nil, colour: nil, result: result}

  # A small TRF16 file (the engines' spelling: no 162/192/202) from
  # `games_by_rank`, with `lines` inserted after the header records - the
  # way a third party's file carries a record this test is about.
  defp trf(games_by_rank, tournament \\ %{}, lines \\ []) do
    names = ~w(Alpha Bravo Charlie Delta Echo Foxtrot)

    players =
      for {rank, games} <- Enum.sort(games_by_rank) do
        %{
          rank: rank,
          name: "#{Enum.at(names, rank - 1)}, Player",
          points: Enum.reduce(games, 0.0, &(&2 + Trf.points_for_game(&1))),
          games: games
        }
      end

    text =
      Trf.serialize(%{
        tournament:
          Map.merge(%{name: "Adjusted", type: "swiss", number_of_rounds: 5}, tournament),
        players: players
      })

    String.replace(
      text,
      "092 ",
      Enum.map_join(lines, "", &(&1 <> "\r\n")) <> "092 ",
      global: false
    )
  end

  # Round 1 of four players, both games drawn.
  defp one_round, do: one_round(%{})

  defp one_round(extra) do
    Map.merge(
      %{
        1 => [game(2, "w", "=")],
        2 => [game(1, "b", "=")],
        3 => [game(4, "w", "=")],
        4 => [game(3, "b", "=")]
      },
      extra
    )
  end

  defp review!(text) do
    assert {:ok, report} = TrfImport.review(text)
    report
  end

  defp codes(report), do: Enum.map(report.adjustments, & &1.code)

  defp find(report, code), do: Enum.find(report.adjustments, &(&1.code == code))

  describe "the TRF version" do
    test "a file with no TRF26 record and real bye codes is TRF16" do
      assert review!(trf(one_round())).version == :trf16
    end

    test "a file with a TRF26 record is TRF26" do
      assert review!(trf(one_round(), %{type_code: "FIDE_DUTCH_2025"})).version == :trf26
    end

    test "a bye written as a game against nobody, with no bye code anywhere, is TRF06" do
      text =
        trf(%{1 => [game(2, "w", "=")], 2 => [game(1, "b", "=")], 3 => [nobody("U")]})
        |> String.replace("0000 - U", "0000 - 1")

      report = review!(text)
      assert report.version == :trf06
      assert %{count: 1, rounds: [1]} = find(report, :old_style_byes)
    end
  end

  describe "what a TRF06/TRF16 file cannot say, defaulted and reported" do
    test "no point system" do
      assert %{win: 1.0, draw: 0.5, loss: +0.0, bye: 1.0} =
               find(review!(trf(one_round())), :default_scoring)

      refute :default_scoring in codes(review!(trf(one_round(), %{point_system: %{win: 3.0}})))
    end

    test "no tournament type code" do
      assert %{pairing_system: "swiss", pairing_engine: "ainalrami"} =
               find(review!(trf(one_round())), :default_system)

      refute :default_system in codes(review!(trf(one_round(), %{type_code: "FIDE_DUTCH_2025"})))
    end

    test "no tie-breaks" do
      assert find(review!(trf(one_round())), :default_tiebreaks)
    end

    test "no number of rounds" do
      text = trf(one_round(), %{number_of_rounds: nil})
      refute text =~ "142 "
      assert %{rounds: 1} = find(review!(text), :default_round_count)
    end
  end

  describe "what the import changed in any file" do
    test "a type code this app has no system for" do
      text =
        one_round()
        |> trf(%{type_code: "CUSTOM_SWISS"})
        |> String.replace("192 CUSTOM_SWISS", "192 FIDE_DUBOV")

      assert %{type_code: "FIDE_DUBOV"} = find(review!(text), :unknown_system_code)
    end

    test "round-robin cycles over two" do
      text =
        %{1 => [game(2, "w", "=")], 2 => [game(1, "b", "=")]}
        |> trf(%{type: "roundrobin", type_code: "CUSTOM_SWISS"})
        |> String.replace("192 CUSTOM_SWISS", "192 BERGER_ROUNDROBIN_G3")

      assert %{requested: 3, used: 2} = find(review!(text), :rr_cycles_clamped)
    end

    test "tie-breaks this app does not compute" do
      report = review!(trf(one_round(), %{tie_breaks: ["BH", "ZZZ"]}))
      assert %{codes: ["ZZZ"]} = find(report, :tiebreaks_dropped)
    end

    test "a declared length shorter than the games" do
      text =
        %{
          1 => [game(2, "w", "="), game(2, "b", "=")],
          2 => [game(1, "b", "="), game(1, "w", "=")]
        }
        |> trf()
        |> String.replace("142 5", "142 1")

      assert %{from: 1, to: 2} = find(review!(text), :round_count_raised)
    end

    test "deputy arbiters past the fourth" do
      report = review!(trf(one_round(), %{deputy_arbiters: ~w(A B C D E F)}))
      assert %{count: 2} = find(report, :deputies_dropped)
    end

    test "362's forfeit and team-bye match points" do
      report = review!(trf(one_round(), %{}, ["362  W 2.0    D 1.0    L 0.0    A 0.5    P 1.0"]))
      assert %{points: 0.5} = find(report, :team_forfeit_points_ignored)
      assert %{points: 1.0} = find(report, :team_pab_points_ignored)
    end

    test "a typed 299 of match points" do
      report = review!(trf(one_round(), %{}, ["299 W   2.0   1.0"]))
      assert %{count: 1} = find(report, :team_match_points_ignored)
    end

    test "299 extra points switch counting on, which is said" do
      line = "299" <> String.duplicate(" ", 10) <> " 1.0" <> String.duplicate(" ", 6) <> "   1"
      report = review!(trf(one_round(), %{}, [line]))
      assert %{players: 1} = find(report, :extra_points_counted)
    end

    test "an opponent who does not name the player back" do
      games = %{
        1 => [game(2, "w", "1")],
        2 => [game(3, "b", "=")],
        3 => [game(2, "w", "=")]
      }

      assert %{count: 1, rounds: [1]} = find(review!(trf(games)), :dangling_opponents)
    end

    test "a full-point bye is no longer an adjustment: it is kept as one (VCL4THP Q177)" do
      games = %{1 => [game(2, "w", "=")], 2 => [game(1, "b", "=")], 3 => [nobody("F")]}
      refute find(review!(trf(games)), :full_point_byes_merged)
    end

    test "rounds of a system that cannot be checked" do
      report = review!(trf(one_round(), %{type: "roundrobin"}))
      assert find(report, :rounds_not_checked)
    end
  end

  describe "the round check" do
    setup do
      on_exit(fn -> Application.delete_env(:pairings_engine, :trf_import_round_check) end)
    end

    test "a crash is reported, not swallowed" do
      Application.put_env(:pairings_engine, :trf_import_round_check, fn _data, _paired ->
        raise "boom"
      end)

      report = review!(trf(one_round()))
      assert Enum.any?(report.warnings, &(&1.kind == :verification_failed))
      assert TrfImport.findings(report)["verification_failed"]
    end
  end

  # Round 2 repeats round 1: two rematches.
  defp rematch_trf do
    trf(%{
      1 => [game(2, "w", "="), game(2, "b", "=")],
      2 => [game(1, "b", "="), game(1, "w", "=")],
      3 => [game(4, "w", "="), game(4, "b", "=")],
      4 => [game(3, "b", "="), game(3, "w", "=")]
    })
  end

  describe "review, findings and the ### line" do
    test "a review is a dry run: nothing is written" do
      before = Repo.aggregate(Tournament, :count)
      report = review!(rematch_trf())

      assert TrfImport.pibe?(report)
      assert Repo.aggregate(Tournament, :count) == before
    end

    test "the import keeps its findings, and the TRF26 report carries the Import PIBE" do
      assert {:ok, tournament, report} = TrfImport.import_with_report(rematch_trf())

      tournament = Repo.get!(Tournament, tournament.id)
      findings = tournament.import_findings

      assert findings["version"] == "TRF16"
      assert findings == TrfImport.findings(report)
      assert [%{"round" => 2, "items" => [_, _]}] = findings["pibe"]

      assert Enum.any?(findings["adjustments"], &(&1["code"] == "default_scoring"))

      tournament =
        tournament
        |> Ecto.Changeset.change(round_dates: ["2026-01-01", "2026-01-02"])
        |> Repo.update!()

      assert {:ok, text} = TrfExport.export(tournament)

      assert text =~
               ~r/### Import @ Round 2: \d-\d \(rematch of round 1\) \d-\d \(rematch of round 1\)/

      # Never in the file sent for rating, and not in the engines' spelling.
      assert {:ok, rating} = TrfExport.export(tournament, nil, for: :rating)
      refute rating =~ "###"
      assert {:ok, engine} = TrfExport.export(tournament, nil, dialect: :engine)
      refute engine =~ "Import @"
    end

    test "a clean file's review has nothing in its PIBE" do
      report = review!(trf(one_round(), %{type_code: "FIDE_DUTCH_2025"}))
      refute TrfImport.pibe?(report)
      assert TrfImport.findings(report)["pibe"] == []
    end
  end
end
