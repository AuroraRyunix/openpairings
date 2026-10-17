defmodule PairingsEngine.Repo.Migrations.AddSexToKbsbPlayers do
  use Ecto.Migration

  # KBSB's `players.sqlite` has carried a `Sex` column all along, and the
  # import has been checking it was there and then throwing it away. Stored
  # now, as the app's own "m"/"w" (see `SqliteFile.to_member_row/2`).
  #
  # Nullable, no default: the rows already on disk were imported without it
  # and `nil` says "not known yet" rather than inventing an answer. They fill
  # in at the next KBSB sync.
  #
  # Which is why the second statement exists. The HTTP sync sends the stored
  # ETag / Last-Modified and skips the download when KBSB answers 304, so
  # pressing "Sync from KBSB" in the same month as the last sync would leave
  # every row sexless until KBSB published a new file. Forgetting the stored
  # validators once makes the next sync a full download. Nothing else reads
  # those keys; the only cost is one unconditional fetch of a ~2 MB file.
  def up do
    alter table(:kbsb_players) do
      add :sex, :string
    end

    execute "DELETE FROM meta WHERE key LIKE 'bel_http_etag:%'"
  end

  def down do
    alter table(:kbsb_players) do
      remove :sex
    end
  end
end
