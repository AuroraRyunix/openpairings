defmodule PairingsEngine.Repo.Migrations.AddSnapshotPinned do
  use Ecto.Migration

  # Pinned snapshots are exempt from `Snapshots.prune/1`'s retention limit.
  #
  # The case this exists for: restoring an earlier state itself captures a
  # snapshot first, so you can step forward again. Without pinning, someone
  # bouncing back and forth between two states would push those very
  # restore-points off the end of the 50-slot window — losing exactly the
  # state they jumped away from, which defeats the point of it being
  # reversible.
  #
  # Default false: ordinary automatic captures stay prunable, or the window
  # would never turn over.
  def change do
    alter table(:tournament_snapshots) do
      add :pinned, :boolean, null: false, default: false
    end
  end
end
