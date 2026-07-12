defmodule PairingsEngine.Repo.Migrations.CreateCoreTables do
  use Ecto.Migration

  def change do
    create table(:tournaments) do
      add :name, :string, null: false
      # swiss | roundrobin | team-swiss | team-roundrobin
      add :type, :string, null: false, default: "swiss"
      add :venue, :string, null: false, default: ""
      add :city, :string, null: false, default: ""
      add :federation, :string, null: false, default: ""
      add :start_date, :string, null: false, default: ""
      add :end_date, :string, null: false, default: ""
      add :organizer, :string, null: false, default: ""
      add :chief_arbiter, :string, null: false, default: ""
      add :deputy_arbiter, :string, null: false, default: ""
      add :time_control, :string, null: false, default: ""
      add :rounds_count, :integer, null: false, default: 9
      # fide | national | none
      add :rating_type, :string, null: false, default: "fide"
      add :points_win, :float, null: false, default: 1.0
      add :points_draw, :float, null: false, default: 0.5
      add :points_loss, :float, null: false, default: 0.0
      add :bye_value, :float, null: false, default: 1.0
      # ordered list of tiebreak codes, stored as JSON
      add :tiebreaks, {:array, :string}, null: false, default: []
      # none | baku
      add :acceleration, :string, null: false, default: "none"
      # setup | running | finished
      add :status, :string, null: false, default: "setup"

      timestamps(type: :utc_datetime)
    end

    create table(:teams) do
      add :tournament_id, references(:tournaments, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :captain, :string, null: false, default: ""
    end

    create index(:teams, [:tournament_id])

    create table(:players) do
      add :tournament_id, references(:tournaments, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :sex, :string, null: false, default: ""
      add :title, :string, null: false, default: ""
      add :fide_id, :integer
      add :fide_rating, :integer, null: false, default: 0
      add :national_id, :string, null: false, default: ""
      add :national_rating, :integer, null: false, default: 0
      add :federation, :string, null: false, default: ""
      add :birth_year, :integer
      add :club, :string, null: false, default: ""
      # active | withdrawn
      add :status, :string, null: false, default: "active"
      add :start_round, :integer, null: false, default: 1
      add :team_id, references(:teams, on_delete: :nilify_all)
      add :board_order, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:players, [:tournament_id])

    create table(:rounds) do
      add :tournament_id, references(:tournaments, on_delete: :delete_all), null: false
      add :number, :integer, null: false
      add :date, :string, null: false, default: ""
      # pairing | playing | finished
      add :status, :string, null: false, default: "pairing"
    end

    create unique_index(:rounds, [:tournament_id, :number])

    create table(:matches) do
      add :round_id, references(:rounds, on_delete: :delete_all), null: false
      add :board, :integer, null: false
      add :team_a_id, references(:teams, on_delete: :nilify_all)
      add :team_b_id, references(:teams, on_delete: :nilify_all)
    end

    create table(:pairings) do
      add :round_id, references(:rounds, on_delete: :delete_all), null: false
      add :board, :integer, null: false
      add :white_player_id, references(:players, on_delete: :nilify_all)
      add :black_player_id, references(:players, on_delete: :nilify_all)
      # "" | 1-0 | 1/2-1/2 | 0-1 | 1-0FF | 0-1FF | 0-0FF | 0-0 | bye
      # (+-- | --+ kept accepted for historical/SWAR-imported data)
      add :result, :string, null: false, default: ""
      add :match_id, references(:matches, on_delete: :delete_all)
    end

    create index(:pairings, [:round_id])

    create table(:byes) do
      add :tournament_id, references(:tournaments, on_delete: :delete_all), null: false
      add :player_id, references(:players, on_delete: :delete_all), null: false
      add :round, :integer, null: false
      # requested-half | requested-zero | absent | pairing-allocated
      add :type, :string, null: false, default: "requested-half"
    end

    create unique_index(:byes, [:player_id, :round])

    create table(:forbidden_pairings) do
      add :tournament_id, references(:tournaments, on_delete: :delete_all), null: false
      add :player_a_id, references(:players, on_delete: :delete_all), null: false
      add :player_b_id, references(:players, on_delete: :delete_all), null: false
    end

    # Local copy of the FIDE rating list (synced from ratings.fide.com)
    create table(:fide_players, primary_key: false) do
      add :fide_id, :integer, primary_key: true
      add :name, :string, null: false
      add :federation, :string, null: false, default: ""
      add :sex, :string, null: false, default: ""
      add :title, :string, null: false, default: ""
      add :standard_rating, :integer
      add :rapid_rating, :integer
      add :blitz_rating, :integer
      add :birth_year, :integer
      add :flag, :string, null: false, default: ""
    end

    create index(:fide_players, [:name])

    create table(:meta, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :string
    end
  end
end
