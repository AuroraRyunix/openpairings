defmodule PairingsEngine.Repo.Migrations.AddSwarAdminFields do
  use Ecto.Migration

  def change do
    alter table(:players) do
      # nopaid | paid | gratis (SWAR §5.20)
      add :paid, :string, null: false, default: "paid"
      # SWAR Aff. (§5.21) - 0=not affiliated maps to false, 1/2 to true
      add :affiliated, :boolean, null: false, default: true
      # SWAR Absent checkbox - player not paired at all while set
      add :absent, :boolean, null: false, default: false
      # SWAR Forfeit - player withdrawn/forfeited out
      add :forfeit, :boolean, null: false, default: false
      # Fixed-table accommodation (SWAR HandyTable) - informational only
      add :special_table, :boolean, null: false, default: false
      # Comma-separated round numbers, e.g. "3,5"
      add :absent_rounds, :string, null: false, default: ""
      # SWAR XtPts
      add :extra_points, :float, null: false, default: 0.0
      # SWAR player category (name, if resolvable from the CATEGORIES section)
      add :category, :string, null: false, default: ""
      # SWAR N° Club (club NAME keeps going to the existing `club` field)
      add :club_number, :integer
    end

    alter table(:tournaments) do
      # standard | rapid | blitz
      add :standard, :string, null: false, default: "standard"
      add :rate_of_play, :string, null: false, default: ""
      add :organizer_club_number, :string, null: false, default: ""
      # ISO dates, index = round-1
      add :round_dates, {:array, :string}, null: false, default: []
      # tournament-defined category names
      add :categories, {:array, :string}, null: false, default: []
    end
  end
end
