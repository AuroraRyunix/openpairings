defmodule PairingsEngine.Repo.Migrations.CreateMobileEnrollments do
  use Ecto.Migration

  # No-account "enrol a phone" grants for mobile result entry. The arbiter
  # generates one per tournament; a helper scans the QR (carrying `token`) or
  # types the short numeric `code`, and that browser gets a result-entry-only
  # session scoped to `tournament_id` until `expires_at` or `revoked_at`.
  def change do
    create table(:mobile_enrollments) do
      add :tournament_id, references(:tournaments, on_delete: :delete_all), null: false
      add :token, :string, null: false
      add :code, :string, null: false
      add :label, :string, default: ""
      add :expires_at, :utc_datetime, null: false
      add :revoked_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:mobile_enrollments, [:token])
    create index(:mobile_enrollments, [:tournament_id])
    create index(:mobile_enrollments, [:code])
  end
end
