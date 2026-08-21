defmodule PairingsEngine.Repo.Migrations.AddTournamentArchivedAt do
  use Ecto.Migration

  # Deliberately a separate nullable column rather than a new `status` value:
  # `tournaments.status` is DERIVED (Tournaments.derive_status/1 recomputes it
  # from the round/pairing rows on every refresh_status!/1 call), so an
  # "archived" status would be silently clobbered the next time anything
  # touched the tournament. `archived_at` mirrors `deleted_at` instead - an
  # independent, explicitly-set timestamp that nothing derives.
  #
  # No backfill: every existing tournament gets NULL, which reads as
  # "not archived" everywhere, so this migration cannot change the behaviour
  # of any tournament that already exists.
  def change do
    alter table(:tournaments) do
      add :archived_at, :utc_datetime
    end

    # Every listing path filters on this alongside deleted_at.
    create index(:tournaments, [:archived_at])
  end
end
