defmodule PairingsEngine.Repo.Migrations.AddRoundsResultsPublic do
  @moduledoc """
  Adds `rounds.results_public` - the "Results round N" publish switch. See
  `PairingsEngine.Tournaments.Round`'s field doc and
  `PairingsEngine.Tournaments.results_public?/2` for what it means.

  New rounds default to `false`: a round's pairings can be public while the
  results typed into it stay on the arbiter's machine until switched on.

  ## The backfill is the point

  Until this column existed, a published round's results reached the public
  site as soon as they were typed. Defaulting every existing row to `false`
  would take results that are public right now off the air at the next
  publish, in the middle of a running event, with nothing on either side to
  explain it. So every round that is published at migration time - the same
  reading as `Tournaments.round_published?/2`, reproduced here over raw
  queries for the reason `20260911130000_add_standings_through.exs` gives -
  gets `true`. A round that is paired but not yet public keeps the new
  default: nobody has seen its results, so nothing is taken away.

  `PairingsEngine.TournamentImport` applies the same rule to a backup written
  before the column existed.
  """
  use Ecto.Migration

  import Ecto.Query

  def up do
    alter table(:rounds) do
      add :results_public, :boolean, default: false, null: false
    end

    flush()

    backfill(repo())
  end

  def down do
    alter table(:rounds) do
      remove :results_public
    end
  end

  # Public so a test can run the data half against rows it built, without
  # rolling the schema back and forth under the SQL sandbox.
  @doc false
  def backfill(repo) do
    now = DateTime.utc_now()

    modes =
      repo.all(from(t in "tournaments", select: {t.id, type(t.publish_mode, :string)}))
      |> Map.new()

    rounds =
      repo.all(
        from(r in "rounds",
          select: %{
            id: r.id,
            tournament_id: r.tournament_id,
            published_at: type(r.published_at, :utc_datetime)
          }
        )
      )

    ids =
      for round <- rounds,
          round_published?(Map.get(modes, round.tournament_id), round.published_at, now),
          do: round.id

    ids
    |> Enum.chunk_every(500)
    |> Enum.each(fn chunk ->
      # `type/2`, because a schemaless query has no field type to dump a bare
      # `true` through, and SQLite then stores the TEXT "true" - which the
      # `Round` schema refuses to load.
      repo.update_all(
        from(r in "rounds",
          where: r.id in ^chunk,
          update: [set: [results_public: type(^true, :boolean)]]
        ),
        []
      )
    end)
  end

  defp round_published?("immediate", _published_at, _now), do: true
  defp round_published?(_mode, nil, _now), do: false
  defp round_published?(_mode, published_at, now), do: DateTime.compare(published_at, now) != :gt
end
