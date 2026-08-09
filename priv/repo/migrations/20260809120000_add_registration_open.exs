defmodule PairingsEngine.Repo.Migrations.AddRegistrationOpen do
  use Ecto.Migration

  # Self-registration is OFF by default, and deliberately so: it is the one
  # public page that WRITES, and an existing tournament must not silently
  # start accepting strangers because it upgraded.
  def change do
    alter table(:tournaments) do
      add :registration_open, :boolean, null: false, default: false
    end
  end
end
