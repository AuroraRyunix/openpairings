defmodule PairingsEngine.Repo.Migrations.AddRatingProvenanceToPlayers do
  @moduledoc """
  Where a player's FIDE rating came from, kept beside the rating itself.

    * `players.fide_rating_source` - the FIDE list it was read from
      (`"standard"`, `"rapid"` or `"blitz"`), `NULL` when it was typed by hand
      or arrived from an import that does not say.
    * `players.fide_rating_period` - the monthly list (`"YYYY-MM"`) that value
      belongs to.
    * `players.fide_rating_listed` - the value as the list printed it, so a
      rating the arbiter later changes by hand is recognisable as modified
      while its source stays on record.

  It also gives the already-downloaded FIDE list a recorded period
  (`meta.fide_list_period`), taken from the month of its last sync, so the
  consistency check can say which list it compared against.
  """
  use Ecto.Migration

  def up do
    alter table(:players) do
      add :fide_rating_source, :string
      add :fide_rating_period, :string
      add :fide_rating_listed, :integer
    end

    execute("""
    INSERT INTO meta (key, value)
    SELECT 'fide_list_period', substr(value, 1, 7) FROM meta
    WHERE key = 'fide_last_sync' AND length(value) >= 7
    ON CONFLICT(key) DO NOTHING
    """)
  end

  def down do
    execute("DELETE FROM meta WHERE key = 'fide_list_period'")

    alter table(:players) do
      remove :fide_rating_source
      remove :fide_rating_period
      remove :fide_rating_listed
    end
  end
end
