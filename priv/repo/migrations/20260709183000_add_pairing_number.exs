defmodule PairingsEngine.Repo.Migrations.AddPairingNumber do
  use Ecto.Migration

  def change do
    alter table(:players) do
      # TRF starting rank; frozen when round 1 is paired so that editing a
      # rating later can never silently renumber the pairing history.
      add :pairing_number, :integer
    end
  end
end
