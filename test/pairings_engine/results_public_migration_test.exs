defmodule PairingsEngine.ResultsPublicMigrationTest do
  @moduledoc """
  The data half of `AddRoundsResultsPublic`: every round published at
  migration time keeps its results public, because they were public the
  moment before. Run against rows built here rather than by rolling the
  schema back, which the SQL sandbox does not allow.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.Repo
  alias PairingsEngine.Tournaments.{Round, Tournament}

  @migration PairingsEngine.Repo.Migrations.AddRoundsResultsPublic
  @file_path "priv/repo/migrations/20260913150000_add_rounds_results_public.exs"

  setup_all do
    unless Code.ensure_loaded?(@migration), do: Code.require_file(@file_path)
    :ok
  end

  defp tournament(mode) do
    Repo.insert!(%Tournament{name: mode, type: "swiss", rounds_count: 5, publish_mode: mode})
  end

  defp round(t, number, published_at) do
    Repo.insert!(%Round{tournament_id: t.id, number: number, published_at: published_at})
  end

  defp results_public?(round), do: Repo.reload!(round).results_public

  test "published rounds get true; unpublished and future-published rounds keep false" do
    past = DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)
    future = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)

    manual = tournament("manual")
    published = round(manual, 1, past)
    held_back = round(manual, 2, nil)

    timed = tournament("timed")
    not_yet = round(timed, 1, future)

    # "immediate" treats every round as published whatever its timestamp.
    immediate = tournament("immediate")
    immediate_round = round(immediate, 1, nil)

    for r <- [published, held_back, not_yet, immediate_round], do: refute(results_public?(r))

    # `apply/3`: the module is loaded at runtime, from priv, not compiled with
    # the test suite.
    apply(@migration, :backfill, [Repo])

    assert results_public?(published)
    refute results_public?(held_back)
    refute results_public?(not_yet)
    assert results_public?(immediate_round)
  end
end
