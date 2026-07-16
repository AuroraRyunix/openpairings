defmodule PairingsEngine.Repo.Migrations.CreateAuditLogs do
  use Ecto.Migration

  def change do
    create table(:audit_logs) do
      add :tournament_id, references(:tournaments, on_delete: :delete_all), null: false
      # Nullable: some writes (a public/no-auth `/tools` action, a background
      # sync) have no attributable user. Most rows will carry one.
      add :user_id, references(:users, on_delete: :nilify_all)
      add :action, :string, null: false
      add :details, :map, null: false, default: %{}

      timestamps(updated_at: false)
    end

    # Chronological per-tournament listing is the primary access pattern —
    # every audit query filters by tournament_id and orders by inserted_at.
    create index(:audit_logs, [:tournament_id, :inserted_at])
    # Filtering by action type (the audit page's category filter).
    create index(:audit_logs, [:tournament_id, :action])
  end
end
