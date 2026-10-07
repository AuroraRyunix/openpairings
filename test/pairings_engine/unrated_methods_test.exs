defmodule PairingsEngine.UnratedMethodsTest do
  @moduledoc """
  VCL4THP Q209: more than one method for an unrated player in the
  rating-based tie-breaks - the fixed rating, the lowest rating in the field
  and the average of the rated players. Ainalrami can only be told a number
  (`/U<rating>`), so the last two are worked out here and written as the
  number they come to: the TRF `202` line says what the standings used and
  `ainalrami -c` finds no disagreement.
  """
  use PairingsEngine.DataCase, async: false

  import ExUnit.CaptureIO

  alias Ainalrami.Tiebreaks.Event
  alias PairingsEngine.{Pairing, Repo, Standings, Tournaments, TrfExport}
  alias PairingsEngine.Standings.AinalramiBridge
  alias PairingsEngine.Tournaments.Tournament

  @results ~w(1-0 0-1 1/2-1/2 1-0 0-1)

  # Ratings 2363 2326 2289 2252 (unrated) 2178 2141 2104: lowest 2104,
  # average of the seven rated 2236.14.
  setup do
    t =
      Repo.insert!(%Tournament{
        name: "Unrated methods",
        type: "swiss",
        rounds_count: 4,
        tiebreaks: ~w(BHC1 ARO TPR AROC1 SB),
        round_dates: for(r <- 1..4, do: "2026-09-0#{r}")
      })

    for i <- 1..8 do
      {:ok, _} =
        Tournaments.create_player(t.id, %{
          tournament_id: t.id,
          name: "Player #{i}",
          fide_rating: if(i == 5, do: 0, else: 2400 - 37 * i)
        })
    end

    for _ <- 1..4 do
      {:ok, round} = Pairing.pair_next_round(Repo.reload!(t), [])
      round = Tournaments.get_round(t.id, round.number)

      for {p, i} <- Enum.with_index(round.pairings), p.black_player_id do
        {:ok, _} =
          Tournaments.update_pairing_result(p, Enum.at(@results, rem(i + round.number, 5)))
      end
    end

    %{t: Repo.reload!(t)}
  end

  defp players(t), do: Tournaments.list_players(t.id)

  defp check(text) do
    path = Path.join(System.tmp_dir!(), "op_unrated_#{System.unique_integer([:positive])}.trf")
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

  test "fixed with no rating still drops the rating-based tie-breaks", %{t: t} do
    assert Standings.unrated_rating(t, players(t)) == nil

    assert Standings.dropped_tiebreaks_with_reasons(t) ==
             [{"ARO", :unrated_present}, {"TPR", :unrated_present}, {"AROC1", :unrated_present}]
  end

  test "fixed uses the stored rating", %{t: t} do
    t = %{t | tiebreak_unrated_rating: 1500}
    assert Standings.unrated_rating(t, players(t)) == 1500
  end

  test "lowest counts an unrated player as the lowest rating of the field", %{t: t} do
    t = %{t | tiebreak_unrated_method: "lowest"}
    assert Standings.unrated_rating(t, players(t)) == 2104
    assert Standings.dropped_tiebreaks(t) == []
  end

  test "average counts an unrated player as the average of the rated ones", %{t: t} do
    t = %{t | tiebreak_unrated_method: "average"}
    assert Standings.unrated_rating(t, players(t)) == 2236
    assert Standings.dropped_tiebreaks(t) == []
  end

  test "the methods give different tie-break values", %{t: t} do
    aro = fn method ->
      %{t | tiebreak_unrated_method: method}
      |> Standings.standings()
      |> Enum.map(& &1.tiebreaks["ARO"])
    end

    refute aro.("lowest") == aro.("average")
  end

  for {method, rating} <- [{"lowest", 2104}, {"average", 2236}] do
    test "#{method}: the TRF says what was used and the checker agrees", %{t: t} do
      t = %{t | tiebreak_unrated_method: unquote(method)}
      {:ok, text} = TrfExport.export(t)

      assert text =~
               "202 BH/C1,ARO/U#{unquote(rating)},TPR/U#{unquote(rating)},ARO/C1/U#{unquote(rating)},SB"

      assert {0, _} = check(text)

      resolved = Standings.with_unrated_rating(t, players(t))
      event = text |> Ainalrami.Trf.parse() |> Event.from_trf()
      entries = Standings.standings(t)

      for code <- ~w(ARO TPR AROC1) do
        c07 = AinalramiBridge.c07_code(code, resolved)
        {:ok, values} = Ainalrami.Tiebreaks.compute(event, [c07])
        theirs = values |> Map.values() |> hd()
        assert is_map(theirs), "#{code}: the checker dropped it"

        for entry <- entries do
          assert_in_delta entry.tiebreaks[code],
                          (theirs[entry.player.pairing_number] || 0) * 1.0,
                          1.0e-6
        end
      end
    end
  end

  test "the method is validated and saved", %{t: t} do
    assert {:error, changeset} = Tournaments.update_tournament(t, %{tiebreak_unrated_method: "x"})
    assert %{tiebreak_unrated_method: [_ | _]} = errors_on(changeset)
    assert {:ok, t} = Tournaments.update_tournament(t, %{tiebreak_unrated_method: "lowest"})
    assert t.tiebreak_unrated_method == "lowest"
  end
end
