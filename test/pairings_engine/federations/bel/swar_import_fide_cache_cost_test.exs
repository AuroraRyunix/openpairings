defmodule PairingsEngine.Federations.BEL.SwarImportFideCacheCostTest do
  @moduledoc """
  Matching an uploaded `.swar` against the local FIDE list must not cost one
  full scan of it per country named in the file.

  `build_fide_candidates_cache/1` looked the rating list up by federation,
  once per distinct country string among the players SWAR carries no FIDE id
  for - against an unindexed column, so each one was a sequential scan of all
  1.9M rows. Nothing bounds how many distinct strings a file names: it is
  free text, one per player, so the file decides how many scans the server
  performs before a single row is written.

  Both halves are asserted here - the index exists, and the number of
  lookups no longer follows the number of countries.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.Federations.BEL.{SwarExport, SwarImport}
  alias PairingsEngine.Repo
  alias PairingsEngine.Tournaments.{Player, Tournament}

  # Deliberately not real country codes: nothing in the seeded list matches
  # them, which is the honest shape of a file full of junk countries.
  @federations for a <- ?A..?E, b <- ?A..?H, do: <<?Z, a, b>>

  defp tournament_with_a_player_per_federation do
    tournament =
      Repo.insert!(%Tournament{
        name: "Forty flags",
        type: "swiss",
        pairing_system: "swiss",
        rounds_count: 1,
        round_dates: ["2026-08-01"],
        start_date: "2026-08-01",
        end_date: "2026-08-01",
        federation: "BEL",
        swar_guid: "cost-test-guid"
      })

    for {federation, n} <- Enum.with_index(@federations, 1) do
      Repo.insert!(%Player{
        tournament_id: tournament.id,
        name: "Player #{n}",
        sex: "m",
        title: "",
        federation: federation,
        club: "",
        paid: "paid",
        affiliated: true
      })
    end

    tournament
  end

  defp exported_swar_path(tournament) do
    path =
      Path.join(
        System.tmp_dir!(),
        "fide-cache-cost-#{System.unique_integer([:positive])}.swar"
      )

    File.write!(path, SwarExport.export(tournament.id))
    path
  end

  # Ecto emits `[:pairings_engine, :repo, :query]` for every query it runs,
  # in whichever process ran it - so the handler filters on this test's pid.
  defp count_repo_queries(fun) do
    test_pid = self()
    ref = make_ref()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      [:pairings_engine, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == test_pid, do: send(test_pid, {ref, metadata.query})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    drain_queries(ref, [])
  end

  defp drain_queries(ref, acc) do
    receive do
      {^ref, query} -> drain_queries(ref, [query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "forty countries in one file cost one lookup, not forty" do
    path = tournament_with_a_player_per_federation() |> exported_swar_path()

    queries =
      try do
        count_repo_queries(fn -> assert {:ok, _prepared} = SwarImport.prepare_import(path) end)
      after
        File.rm(path)
      end

    # The only query in this path that constrains `federation` is the
    # candidates cache; the name matcher goes through the FTS index, which
    # names `fide_players_fts` and no column at all.
    lookups = Enum.filter(queries, &String.contains?(&1, ~s("federation")))

    assert length(lookups) == 1,
           "#{length(lookups)} federation lookups for #{length(@federations)} countries - " <>
             "the cache is querying per country again:\n" <> Enum.join(lookups, "\n")
  end

  test "the federation lookup is served by an index" do
    %{rows: plan} =
      Repo.query!("EXPLAIN QUERY PLAN SELECT fide_id FROM fide_players WHERE federation = ?", [
        "BEL"
      ])

    detail = plan |> Enum.map(&List.last/1) |> Enum.join(" ")

    assert detail =~ "fide_players_federation_index",
           "the rating list is scanned rather than indexed by federation: #{detail}"
  end
end
