defmodule PairingsEngine.Repo.Migrations.IndexFidePlayerFederation do
  use Ecto.Migration

  # `SwarImport.build_fide_candidates_cache/1` looks the rating list up by
  # federation, for every distinct country string an uploaded `.swar` names.
  # The column had no index, so each of those was a sequential scan of all
  # 1.9M rows - and the number of them is decided by the file, not by us.
  #
  # The table is a downloaded mirror rebuilt by the FIDE sync (see
  # `PairingsEngine.Backup`'s `@reproducible`), so the index costs one column
  # of write amplification on a bulk load that already rebuilds an FTS5 index
  # per row, and nothing at all on the read paths that do not use it.
  def change do
    create index(:fide_players, [:federation])
  end
end
