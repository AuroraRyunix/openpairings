defmodule PairingsEngine.Repo.Migrations.CreateFidePlayersFts do
  use Ecto.Migration

  # Full-text index over FIDE player names so the add-player search can match
  # any name token (first name, last name, in any order, comma optional) fast
  # — a plain LIKE '%token%' can't use an index and scans all ~1.9M rows.
  #
  # Standalone (not external-content) FTS5 table keyed by fide_id, kept in sync
  # by PairingsEngine.Fide.Sync after each rating-list rebuild. `remove_diacritics`
  # so "Muller" finds "Müller". Backfills from whatever is already imported.
  def up do
    execute("""
    CREATE VIRTUAL TABLE fide_players_fts USING fts5(
      fide_id UNINDEXED,
      name,
      tokenize = 'unicode61 remove_diacritics 2'
    )
    """)

    # Keep the index in lock-step with `fide_players` on every write — the
    # monthly sync's bulk delete/insert, test fixtures, ad-hoc corrections —
    # so nothing has to remember to refresh it.
    execute("""
    CREATE TRIGGER fide_players_fts_ai AFTER INSERT ON fide_players BEGIN
      INSERT INTO fide_players_fts(fide_id, name) VALUES (new.fide_id, new.name);
    END
    """)

    execute("""
    CREATE TRIGGER fide_players_fts_ad AFTER DELETE ON fide_players BEGIN
      DELETE FROM fide_players_fts WHERE fide_id = old.fide_id;
    END
    """)

    execute("""
    CREATE TRIGGER fide_players_fts_au AFTER UPDATE ON fide_players BEGIN
      DELETE FROM fide_players_fts WHERE fide_id = old.fide_id;
      INSERT INTO fide_players_fts(fide_id, name) VALUES (new.fide_id, new.name);
    END
    """)

    # Backfill whatever is already imported (the triggers only cover future
    # writes).
    execute("INSERT INTO fide_players_fts(fide_id, name) SELECT fide_id, name FROM fide_players")
  end

  def down do
    execute("DROP TRIGGER IF EXISTS fide_players_fts_ai")
    execute("DROP TRIGGER IF EXISTS fide_players_fts_ad")
    execute("DROP TRIGGER IF EXISTS fide_players_fts_au")
    execute("DROP TABLE fide_players_fts")
  end
end
