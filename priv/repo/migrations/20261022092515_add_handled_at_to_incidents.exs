defmodule PairingsEngine.Repo.Migrations.AddHandledAtToIncidents do
  use Ecto.Migration

  # An incident nobody could mark as dealt with stayed highlighted for the
  # rest of the event. The timestamp is the flag: nil is open.
  def change do
    alter table(:incidents) do
      add :handled_at, :utc_datetime
    end
  end
end
