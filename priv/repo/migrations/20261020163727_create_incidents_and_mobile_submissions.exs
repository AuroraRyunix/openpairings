defmodule PairingsEngine.Repo.Migrations.CreateIncidentsAndMobileSubmissions do
  use Ecto.Migration

  # Manubrium, phase 1 (docs/manubrium.md).
  #
  # `incidents` - what happened at a board, logged from a phone: kept per
  # tournament / round number / board, so it outlives a re-pairing (the
  # pairing reference is nilified, the round number and board stay) and a
  # snapshot restore, like the audit trail.
  #
  # `mobile_submissions` - the answer the server gave each queued entry a
  # phone sent, under the phone's own id for it, so a resend after a lost
  # reply gets the same answer back instead of a second write.
  def change do
    create table(:incidents) do
      add :tournament_id, references(:tournaments, on_delete: :delete_all), null: false
      add :round_number, :integer, null: false
      add :board, :integer, null: false
      add :pairing_id, references(:pairings, on_delete: :nilify_all)
      add :white_player_id, references(:players, on_delete: :nilify_all)
      add :black_player_id, references(:players, on_delete: :nilify_all)
      # The names as the board showed them, kept because the player rows are
      # not: a snapshot restore or a re-import recreates players with new
      # ids, and an incident report that has lost who was involved is a
      # list of board numbers.
      add :white_name, :string, null: false, default: ""
      add :black_name, :string, null: false, default: ""
      add :kind, :string, null: false
      add :note, :string, null: false, default: ""
      add :occurred_at, :utc_datetime, null: false
      add :source, :string, null: false, default: "phone"
      add :enrollment_id, references(:mobile_enrollments, on_delete: :nilify_all)
      add :enrollment_label, :string, null: false, default: ""
      add :client_id, :string

      timestamps(type: :utc_datetime)
    end

    create index(:incidents, [:tournament_id, :round_number])
    create index(:incidents, [:enrollment_id])
    create index(:incidents, [:pairing_id])
    create index(:incidents, [:white_player_id])
    create index(:incidents, [:black_player_id])
    create unique_index(:incidents, [:enrollment_id, :client_id])

    create table(:mobile_submissions) do
      add :enrollment_id, references(:mobile_enrollments, on_delete: :delete_all), null: false
      add :client_id, :string, null: false
      add :kind, :string, null: false
      add :status, :string, null: false
      add :reason, :string, null: false, default: ""
      add :board, :integer

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:mobile_submissions, [:enrollment_id, :client_id])
  end
end
