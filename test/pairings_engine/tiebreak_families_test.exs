defmodule PairingsEngine.TiebreakFamiliesTest do
  @moduledoc """
  Every individual C.07 tie-break the catalogue offers (VCL4THP Q104 for round
  robins, Q199 for Swiss), the rating a tournament counts an unrated player as
  (Q208) and a place shared by players the list leaves level (Q203).

  The values are compared with Ainalrami's own, reached the way FIDE's checker
  reaches them: the TRF this app writes, parsed back, as an
  `Ainalrami.Tiebreaks.Event`. The standings page's numbers and the checker's
  therefore cannot differ without one of these failing.
  """
  # async: false - it pairs whole tournaments, and SQLite takes one writer.
  use PairingsEngine.DataCase, async: false

  import ExUnit.CaptureIO

  alias Ainalrami.Tiebreaks.Event
  alias PairingsEngine.{Pairing, Repo, Standings, Tiebreaks, Tournaments, TrfExport, TrfImport}
  alias PairingsEngine.Standings.AinalramiBridge
  alias PairingsEngine.Tournaments.Tournament

  @results ~w(1-0 0-1 1/2-1/2 1-0 0-1)

  @new_swiss ~w(AOB AOB/F APPO APRO ARO/C2 ARO/M1 ARO/M2 BH/M2 BWG DE/P FB FB/C1 FB/C2
                FB/M1 FB/M2 PS/C1 PS/C2 PTP REP RTNG RTNG/R SB/C1 SB/C2 STD TPN TPN/R TPR)

  @new_rr ~w(KS/L1 KS/L2 KS/L-1 KS/L-2 BWG DE/P REP STD SB/C1 SB/C2 RTNG RTNG/R TPN TPN/R)

  defp played_tournament(players, rounds, tiebreaks, attrs \\ %{}, unrated \\ []) do
    t =
      Repo.insert!(
        struct!(
          %Tournament{
            name: "Families",
            type: "swiss",
            rounds_count: rounds,
            tiebreaks: tiebreaks,
            round_dates: for(r <- 1..rounds, do: "2026-09-#{String.pad_leading("#{r}", 2, "0")}")
          },
          attrs
        )
      )

    for i <- 1..players do
      {:ok, _} =
        Tournaments.create_player(t.id, %{
          tournament_id: t.id,
          name: "Player #{i}",
          fide_rating: if(i in unrated, do: 0, else: 2400 - 37 * i)
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

  # Ainalrami's value of `c07` for every starting rank, from the TRF text.
  defp checker_values(text, c07) do
    event = text |> Ainalrami.Trf.parse() |> Event.from_trf()
    {:ok, values} = Ainalrami.Tiebreaks.compute(event, [c07])
    values |> Map.values() |> hd()
  end

  defp assert_matches_checker(t, codes) do
    {:ok, text} = TrfExport.export(t)
    entries = Standings.standings(t)

    for code <- codes do
      c07 = AinalramiBridge.c07_code(code, t)
      theirs = checker_values(text, c07)

      assert is_map(theirs), "#{code}: the checker dropped it"

      for entry <- entries do
        ours = entry.tiebreaks[code]
        expected = (theirs[entry.player.pairing_number] || 0) * 1.0

        assert_in_delta ours,
                        expected,
                        1.0e-6,
                        "#{code}, player #{entry.player.pairing_number}: #{ours} vs checker #{expected}"
      end
    end
  end

  defp check(text) do
    path = Path.join(System.tmp_dir!(), "op_families_#{System.unique_integer([:positive])}.trf")
    File.write!(path, text)

    try do
      with_io(:stderr, fn ->
        capture_io(fn -> send(self(), {:code, Ainalrami.CLI.run([path, "-c"])}) end)
        receive do: ({:code, code} -> code)
      end)
    after
      File.rm(path)
    end
  end

  describe "the catalogue" do
    test "offers every C.07 individual tie-break FIDE's checklist lists" do
      offered = Tiebreaks.selectable("swiss") |> Enum.map(& &1.code)

      for code <- @new_swiss ++ @new_rr, do: assert(code in offered, "#{code} is not offered")

      # The 39 of Q199, in this app's spelling for the four it spells its own way.
      c07 = Enum.map(offered, &AinalramiBridge.c07_code/1)
      assert length(Enum.uniq(c07)) == length(c07)

      for name <- Ainalrami.Tiebreaks.Code.names(),
          name not in (~w(PTS) ++
                         Enum.filter(
                           Ainalrami.Tiebreaks.Code.names(),
                           &Ainalrami.Tiebreaks.Code.team?/1
                         )),
          do: assert(Enum.any?(c07, &String.starts_with?(&1, name)), "#{name} has no code")
    end

    test "every code is one Ainalrami parses back to itself, and the picker groups hold them all" do
      for %{code: code, scope: scope} <- Tiebreaks.catalogue(), scope != :team do
        c07 = AinalramiBridge.c07_code(code)
        assert {:ok, parsed} = Ainalrami.Tiebreaks.Code.parse(c07)
        assert Ainalrami.Tiebreaks.Code.format(parsed) == c07
      end

      grouped = Tiebreaks.selectable_grouped("swiss") |> Enum.flat_map(&elem(&1, 1))

      assert Enum.sort(Enum.map(grouped, & &1.code)) ==
               Enum.sort(Enum.map(Tiebreaks.selectable("swiss"), & &1.code))

      assert Tiebreaks.selectable_grouped("swiss", ["BH"])
             |> Enum.flat_map(&elem(&1, 1))
             |> Enum.all?(&(&1.code != "BH"))
    end

    test "the rating-based and the Buchholz families are flagged" do
      assert Tiebreaks.rating_based?("ARO")
      assert Tiebreaks.rating_based?("AROC1")
      assert Tiebreaks.rating_based?("TPR")
      assert Tiebreaks.rating_based?("RTNG/R")
      refute Tiebreaks.rating_based?("BH")
      refute Tiebreaks.rating_based?("TPN")

      for code <- ~w(BH BHC1 MBH BH/M2 FB FB/M2 AOB AOB/F),
          do: assert(Tiebreaks.buchholz_based?(code))

      for code <- ~w(SB PS ARO TPN DE), do: refute(Tiebreaks.buchholz_based?(code))
    end
  end

  describe "Swiss: each tie-break agrees with the checker" do
    test "the new Buchholz, Sonneborn-Berger, progressive and result tie-breaks" do
      t = played_tournament(13, 6, ["BH"])

      codes = @new_swiss -- ~w(APPO APRO PTP TPR ARO/C2 ARO/M1 ARO/M2 RTNG RTNG/R DE/P)
      t = %{t | tiebreaks: codes}
      assert_matches_checker(t, codes)
    end

    test "the rating-based tie-breaks" do
      t = played_tournament(13, 6, ["BH"])
      codes = ~w(APPO APRO PTP TPR ARO/C2 ARO/M1 ARO/M2 RTNG RTNG/R)
      t = %{t | tiebreaks: codes}
      assert Standings.dropped_tiebreaks(t) == []
      assert_matches_checker(t, codes)
    end

    test "the whole list is ranked, and the checker finds the standings in order" do
      t = played_tournament(13, 6, ~w(BHC1 BH SB DE/P WIN PS/C1 STD FB/M1 BWG TPR AOB/F REP))
      {:ok, text} = TrfExport.export(t)

      assert text =~ "202 BH/C1,BH,SB,DE/P,WIN,PS/C1,STD,FB/M1,BWG,TPR,AOB/F,REP"
      assert {0, _} = check(text)
    end

    test "their spelling reads back as the same codes" do
      list = ~w(BHC1 AOB/F APPO DE/P KS/L-1 TPN/R RTNG/R PS/C2 SB/C1)
      t = played_tournament(10, 3, list)
      {:ok, text} = TrfExport.export(t)

      {:ok, imported, _notes} =
        TrfImport.import_text(text, PairingsEngine.AccountsFixtures.user_scope_fixture())

      assert imported.tiebreaks == list
    end
  end

  describe "round robin: the tie-breaks of the checklist's list" do
    test "each agrees with the checker" do
      t =
        played_tournament(6, 5, ["SB"], %{pairing_system: "round_robin"})

      codes = @new_rr ++ ~w(DE BPG SB WIN KS TPR)
      t = %{t | tiebreaks: codes}
      assert Standings.dropped_tiebreaks(t) == []
      assert_matches_checker(t, codes -- ["DE", "DE/P"])
    end

    test "the Buchholz family is refused there, new members included" do
      t = played_tournament(6, 5, ["SB"], %{pairing_system: "round_robin"})
      t = %{t | tiebreaks: ~w(SB FB AOB BH/M2 FB/C1)}

      assert Standings.dropped_tiebreaks_with_reasons(t) ==
               [
                 {"FB", :round_robin},
                 {"AOB", :round_robin},
                 {"BH/M2", :round_robin},
                 {"FB/C1", :round_robin}
               ]
    end
  end

  describe "an unrated player" do
    setup do
      {:ok, t: played_tournament(8, 4, ~w(BHC1 ARO TPR AROC1 SB), %{}, [5])}
    end

    test "drops the rating-based tie-breaks by default, as Article 10 says", %{t: t} do
      assert Standings.dropped_tiebreaks_with_reasons(t) ==
               [{"ARO", :unrated_present}, {"TPR", :unrated_present}, {"AROC1", :unrated_present}]
    end

    test "counts as the tournament's rating once it is set, and nothing is dropped", %{t: t} do
      t = %{t | tiebreak_unrated_rating: 1400}

      assert Standings.dropped_tiebreaks(t) == []
      assert AinalramiBridge.c07_code("ARO", t) == "ARO/U1400"
      assert AinalramiBridge.c07_code("AROC1", t) == "ARO/C1/U1400"
      assert AinalramiBridge.c07_code("SB", t) == "SB"

      # The checker, handed the same rule on the code, agrees with the standings.
      {:ok, text} = TrfExport.export(t)
      assert text =~ "ARO/U1400"
      assert_matches_checker(t, ~w(ARO TPR AROC1))
    end

    test "a different rating gives different values", %{t: t} do
      low = Standings.standings(%{t | tiebreak_unrated_rating: 1000})
      high = Standings.standings(%{t | tiebreak_unrated_rating: 2600})

      aro = fn entries -> Enum.map(entries, & &1.tiebreaks["ARO"]) end
      refute aro.(low) == aro.(high)
    end

    test "the rule travels in the TRF and comes back as the setting", %{t: t} do
      t = %{t | tiebreak_unrated_rating: 1500}
      {:ok, text} = TrfExport.export(t)
      assert text =~ "202 BH/C1,ARO/U1500,TPR/U1500,ARO/C1/U1500,SB"
      assert {0, _} = check(text)

      {:ok, imported, _notes} =
        TrfImport.import_text(text, PairingsEngine.AccountsFixtures.user_scope_fixture())

      assert imported.tiebreaks == ~w(BHC1 ARO TPR AROC1 SB)
      assert imported.tiebreak_unrated_rating == 1500
    end

    test "is validated like the team setting is", %{t: t} do
      assert {:error, changeset} =
               Tournaments.update_tournament(t, %{tiebreak_unrated_rating: 9000})

      assert %{tiebreak_unrated_rating: [_ | _]} = errors_on(changeset)
      assert {:ok, t} = Tournaments.update_tournament(t, %{tiebreak_unrated_rating: 1200})
      assert t.tiebreak_unrated_rating == 1200
      assert {:ok, t} = Tournaments.update_tournament(t, %{tiebreak_unrated_rating: ""})
      assert t.tiebreak_unrated_rating == nil
    end
  end

  describe "a place shared by players the list leaves level" do
    setup do
      # Three rounds, nobody tiebroken: with no tie-breaks at all players on
      # the same score are level.
      t = played_tournament(8, 3, [])
      {:ok, t: t}
    end

    test "every entry carries its C.07 place, and positions stay one after the other", %{t: t} do
      entries = Standings.standings(t)
      assert Enum.map(entries, & &1.rank) == Enum.to_list(1..8)

      for e <- entries do
        same = Enum.filter(entries, &(&1.points == e.points))
        assert e.place == Enum.min(Enum.map(same, & &1.rank))
        assert e.place_shared? == length(same) > 1
      end

      assert Enum.any?(entries, & &1.place_shared?)
    end

    test "off, the shown rank is the position; on, it is the shared place", %{t: t} do
      entries = Standings.standings(t)

      for e <- entries do
        assert Standings.shown_rank(e, t) == e.rank
        assert Standings.shown_rank_label(e, t) == "#{e.rank}"
      end

      t = %{t | shared_places: true}

      for e <- entries do
        assert Standings.shown_rank(e, t) == e.place

        label = Standings.shown_rank_label(e, t)
        assert label == if(e.place_shared?, do: "#{e.place}=", else: "#{e.place}")
      end
    end

    test "a hand-set order is shown as positions", %{t: t} do
      t = %{t | shared_places: true, manual_ranking: true}

      for e <- Standings.standings(t), do: assert(Standings.shown_rank(e, t) == e.rank)
    end

    test "the TRF rank column stays one place after the other either way", %{t: t} do
      {:ok, plain} = TrfExport.export(t)
      {:ok, shared} = TrfExport.export(%{t | shared_places: true})
      assert plain == shared
      assert {0, _} = check(plain)
    end

    test "tie-breaks that separate the players leave no shared place", %{t: t} do
      t = %{t | tiebreaks: ~w(BH SB TPN)}

      for e <- Standings.standings(t), do: refute(e.place_shared?)
    end
  end
end
