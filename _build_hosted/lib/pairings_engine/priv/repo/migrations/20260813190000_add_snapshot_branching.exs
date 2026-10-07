defmodule PairingsEngine.Repo.Migrations.AddSnapshotBranching do
  use Ecto.Migration

  # Turns restore points from a flat list into a tree, so going back and then
  # carrying on differently produces a visible fork rather than silently
  # overwriting the line you were on.
  #
  # The model is deliberately git-shaped:
  #
  #   * `parent_id` - the restore point that was current when this one was
  #     taken. Nil for the first one on a tournament (the root).
  #   * `tournaments.head_snapshot_id` - which restore point the live data
  #     currently corresponds to. Capturing hangs the new snapshot off HEAD
  #     and advances it; restoring moves HEAD to the target, so the *next*
  #     capture hangs off there and the tree forks at that node.
  #
  # HEAD lives on the tournament rather than being derived (e.g. "the most
  # recent snapshot") because after a restore the most recent snapshot is
  # precisely NOT where the live data sits - that's the whole point.
  #
  # Both nullable with no backfill: existing snapshots become a flat set of
  # roots, which renders as parallel single-node lines rather than breaking.
  def change do
    alter table(:tournament_snapshots) do
      add :parent_id, references(:tournament_snapshots, on_delete: :nilify_all)
    end

    alter table(:tournaments) do
      add :head_snapshot_id, references(:tournament_snapshots, on_delete: :nilify_all)
    end

    create index(:tournament_snapshots, [:parent_id])
  end
end
