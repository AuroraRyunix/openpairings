defmodule PairingsEngine.Repo.Migrations.CreateKbsbPlayers do
  use Ecto.Migration

  def change do
    # Local copy of the Belgian national rating list (KBSB/FRBE), imported
    # from an uploaded rating-list file - see docs/kbsb-sync.md for why this
    # is a file upload rather than an HTTP sync like the FIDE list.
    create table(:kbsb_players, primary_key: false) do
      add :national_id, :string, primary_key: true
      add :last_name, :string, null: false
      add :first_name, :string, null: false, default: ""
      add :national_rating, :integer
      add :fide_id, :integer
      add :club_number, :integer
      add :club_name, :string, null: false, default: ""
      add :federation, :string, null: false, default: ""
      add :birth_year, :integer
    end

    create index(:kbsb_players, [:last_name])
    create index(:kbsb_players, [:fide_id])
  end
end
