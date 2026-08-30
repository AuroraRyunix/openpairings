defmodule PairingsEngine.Repo.Migrations.CreateKbsbPlayersFts do
  use Ecto.Migration

  # The same treatment `fide_players` got in
  # `20260726090000_create_fide_players_fts` - KBSB's sibling search never
  # received it.
  #
  # `Kbsb.search/1` matches every token against last OR first name with
  # `LIKE '%token%'`. An infix LIKE cannot use a B-tree index, so
  # `create index(:kbsb_players, [:last_name])` from the original migration
  # has never served a single query: it is the only DB touch of that column,
  # and it is a prefix index against an infix pattern. It is dropped here
  # rather than left to look like coverage that exists.
  #
  # Honest about the scale: this is an admin-only page over tens of thousands
  # of rows, so the scan it replaces cost tens of milliseconds per keystroke,
  # not seconds. The reason to do it is that the two searches sit side by
  # side in the same UI and should not diverge in how they work.
  def up do
    execute("""
    CREATE VIRTUAL TABLE kbsb_players_fts USING fts5(
      national_id UNINDEXED,
      name,
      tokenize = 'unicode61 remove_diacritics 2'
    )
    """)

    # One indexed column holding both names, so a token matches either -
    # which is what the LIKE version did with an OR across two columns.
    execute("""
    CREATE TRIGGER kbsb_players_fts_ai AFTER INSERT ON kbsb_players BEGIN
      INSERT INTO kbsb_players_fts(national_id, name)
      VALUES (new.national_id, new.last_name || ' ' || COALESCE(new.first_name, ''));
    END
    """)

    execute("""
    CREATE TRIGGER kbsb_players_fts_ad AFTER DELETE ON kbsb_players BEGIN
      DELETE FROM kbsb_players_fts WHERE national_id = old.national_id;
    END
    """)

    execute("""
    CREATE TRIGGER kbsb_players_fts_au AFTER UPDATE ON kbsb_players BEGIN
      DELETE FROM kbsb_players_fts WHERE national_id = old.national_id;
      INSERT INTO kbsb_players_fts(national_id, name)
      VALUES (new.national_id, new.last_name || ' ' || COALESCE(new.first_name, ''));
    END
    """)

    execute("""
    INSERT INTO kbsb_players_fts(national_id, name)
    SELECT national_id, last_name || ' ' || COALESCE(first_name, '') FROM kbsb_players
    """)

    drop_if_exists index(:kbsb_players, [:last_name])
  end

  def down do
    create_if_not_exists index(:kbsb_players, [:last_name])
    execute("DROP TRIGGER IF EXISTS kbsb_players_fts_ai")
    execute("DROP TRIGGER IF EXISTS kbsb_players_fts_ad")
    execute("DROP TRIGGER IF EXISTS kbsb_players_fts_au")
    execute("DROP TABLE kbsb_players_fts")
  end
end
