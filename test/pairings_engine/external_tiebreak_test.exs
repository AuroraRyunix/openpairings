defmodule PairingsEngine.ExternalTiebreakTest do
  @moduledoc """
  VCL4THP Q207: tie-break values calculated outside the program, typed per
  player (code "EXT") and used in the ranking where the tournament's tie-break
  list puts them. TRF26 has no record for such a value, so the report leaves
  the code out of its tie-break line.
  """
  use PairingsEngine.DataCase, async: false

  import ExUnit.CaptureIO

  alias PairingsEngine.{Pairing, Repo, Standings, Tiebreaks, Tournaments, TrfExport}
  alias PairingsEngine.Tournaments.Tournament

  @results ~w(1-0 0-1 1/2-1/2 1-0 0-1)

  defp played(tiebreaks) do
    t =
      Repo.insert!(%Tournament{
        name: "External",
        type: "swiss",
        rounds_count: 3,
        tiebreaks: tiebreaks,
        round_dates: for(r <- 1..3, do: "2026-09-0#{r}")
      })

    for i <- 1..8 do
      {:ok, _} =
        Tournaments.create_player(t.id, %{
          tournament_id: t.id,
          name: "Player #{i}",
          fide_rating: 2400 - 37 * i
        })
    end

    for _ <- 1..3 do
      {:ok, round} = Pairing.pair_next_round(Repo.reload!(t), [])
      round = Tournaments.get_round(t.id, round.number)

      for {p, i} <- Enum.with_index(round.pairings), p.black_player_id do
        {:ok, _} =
          Tournaments.update_pairing_result(p, Enum.at(@results, rem(i + round.number, 5)))
      end
    end

    Repo.reload!(t)
  end

  defp set_external(t, values) do
    players = Tournaments.list_players(t.id)

    for {p, v} <- Enum.zip(players, values) do
      {:ok, _} = Tournaments.update_player(p, %{external_tiebreak: v})
    end
  end

  defp check(text) do
    path = Path.join(System.tmp_dir!(), "op_ext_#{System.unique_integer([:positive])}.trf")
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

  test "is in the catalogue and offered, as a calculable individual tie-break" do
    assert %{code: "EXT", scope: :individual} = Tiebreaks.get("EXT")
    assert "EXT" in Enum.map(Tiebreaks.selectable("swiss"), & &1.code)
    assert Tiebreaks.individual_calculable?("EXT")
  end

  test "players level on points are ranked by the typed value, higher first" do
    t = played(["EXT"])
    before = Standings.standings(t)
    assert Enum.any?(before, & &1.place_shared?)

    # A rising value by pairing number: the higher the number, the better.
    players = Tournaments.list_players(t.id) |> Enum.sort_by(& &1.pairing_number)
    set_external(t, Enum.map(1..8, &(&1 * 1.0)))
    after_ = Standings.standings(t)

    for e <- after_, do: assert(e.tiebreaks["EXT"] == e.player.external_tiebreak || 0.0)

    by_points = Enum.group_by(after_, & &1.points)

    for {_points, group} <- by_points, length(group) > 1 do
      tpns = Enum.map(group, & &1.player.pairing_number)
      assert tpns == Enum.sort(tpns, :desc), "level players are not ordered by the typed value"
      assert group |> Enum.map(&Standings.place/1) |> Enum.uniq() |> length() == length(group)
    end

    assert length(players) == 8
  end

  test "no value typed counts as zero" do
    t = played(["EXT"])
    for e <- Standings.standings(t), do: assert(e.tiebreaks["EXT"] == 0.0)
  end

  test "a code after it ranks only those the typed value left level" do
    t = played(["EXT", "TPN"])
    # Everybody gets the same value: the next code, TPN, decides.
    set_external(t, List.duplicate(5.0, 8))
    entries = Standings.standings(t)

    for {_p, group} <- Enum.group_by(entries, & &1.points) do
      tpns = Enum.map(group, & &1.player.pairing_number)
      assert tpns == Enum.sort(tpns)
    end
  end

  test "a code before it decides first" do
    t = played(["TPN", "EXT"])
    set_external(t, Enum.map(1..8, &(&1 * 1.0)))

    # TPN never leaves players level, so EXT changes nothing: lowest number first.
    for {_p, group} <- Enum.group_by(Standings.standings(t), & &1.points) do
      tpns = Enum.map(group, & &1.player.pairing_number)
      assert tpns == Enum.sort(tpns)
    end
  end

  test "the TRF leaves it out of the tie-break line and the checker still reads the file" do
    t = played(["BH", "EXT", "SB"])
    set_external(t, Enum.map(1..8, &(&1 * 1.0)))

    {:ok, text} = TrfExport.export(t)
    assert text =~ ~r/^202 BH,SB\s*$/m
    refute text =~ "EXT"
    assert {code, _} = check(text)
    # Exit 0: the checker found nothing wrong with the file as written. A
    # tie the typed value decided shows as the order inside a shared place,
    # which a checker that cannot know the value does not dispute.
    assert code == 0
  end

  test "it is part of the JSON export of a player" do
    t = played(["EXT"])
    set_external(t, Enum.map(1..8, &(&1 * 1.0)))
    json = PairingsEngine.TournamentExport.export_tournament(t)
    assert inspect(json) =~ "external_tiebreak"
  end
end
