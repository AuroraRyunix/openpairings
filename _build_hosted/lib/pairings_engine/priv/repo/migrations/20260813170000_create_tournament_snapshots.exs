defmodule PairingsEngine.Repo.Migrations.CreateTournamentSnapshots do
  use Ecto.Migration

  # Point-in-time copies of a whole tournament, taken automatically just
  # before an action that is hard or impossible to undo by hand (pairing a
  # round, unpairing one, importing results in bulk, restoring an earlier
  # snapshot). The payload is a `PairingsEngine.TournamentExport` envelope -
  # the same shape as a JSON backup - so one serializer covers both and the
  # restore path is a variant of the importer rather than a second
  # implementation that could drift.
  def change do
    create table(:tournament_snapshots) do
      add :tournament_id, references(:tournaments, on_delete: :delete_all), null: false

      # Which action was about to happen, e.g. "pairing.round_paired". Free
      # text rather than an enum for the same reason the audit log's `action`
      # is: new call sites shouldn't need a migration.
      add :trigger, :string, null: false

      # Who triggered it. Nullable: a system/no-auth write (an automatic
      # sweep, a script) has no acting user, same convention as audit rows.
      add :user_id, references(:users, on_delete: :nilify_all)

      # Short human-readable summary shown in the history list, so the UI
      # never has to decode the whole payload just to render a row.
      add :summary, :string

      # The full export envelope.
      add :payload, :map, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    # Every read is "this tournament's snapshots, newest first".
    create index(:tournament_snapshots, [:tournament_id, :inserted_at])
  end
end
