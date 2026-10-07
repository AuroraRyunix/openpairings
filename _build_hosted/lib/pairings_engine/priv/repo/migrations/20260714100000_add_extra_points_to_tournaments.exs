defmodule PairingsEngine.Repo.Migrations.AddExtraPointsToTournaments do
  use Ecto.Migration

  # Per-tournament "extra points" (SWAR parity #12, SWAR "XtPts"): organizers
  # can grant administrative bonus points (e.g. a handicap head start for
  # lower-rated players). `players.extra_points` already exists (populated by
  # the SWAR importer among others) but standings deliberately do NOT count
  # it unless the tournament opts in via `count_extra_points` - see
  # `PairingsEngine.Standings` and `docs/extra-points.md`. `extra_points_bands`
  # holds the Elo-band auto-assign rule as a comma-separated
  # "threshold:bonus" string (e.g. "1400:1, 1600:0.5"), applied on demand by
  # `PairingsEngine.Tournaments.apply_extra_points_bands/1` - it never runs
  # automatically, so it never silently overwrites hand-edited values.
  def change do
    alter table(:tournaments) do
      add :count_extra_points, :boolean, null: false, default: false
      add :extra_points_bands, :string, null: false, default: ""
    end
  end
end
