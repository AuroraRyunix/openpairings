defmodule PairingsEngine.Repo.Migrations.NocaseNameIndex do
  use Ecto.Migration

  # SQLite's LIKE is case-insensitive, so it can only use an index whose
  # collation is NOCASE. Without this, every search keystroke scans 1.9M rows.
  def up do
    execute "DROP INDEX IF EXISTS fide_players_name_index"
    execute "CREATE INDEX fide_players_name_index ON fide_players (name COLLATE NOCASE)"
  end

  def down do
    execute "DROP INDEX IF EXISTS fide_players_name_index"
    execute "CREATE INDEX fide_players_name_index ON fide_players (name)"
  end
end
