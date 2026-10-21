defmodule PairingsEngine.Repo.Migrations.ManubriumArbitersAndPhotos do
  @moduledoc """
  Manubrium, the rest of it (docs/manubrium.md):

    * a collaborator may be an `arbiter` (results and incidents from the
      hall, nothing else), with the boards the desk assigned them;
    * a phone code may belong to an account, so what it enters is that
      account's in the audit trail - and stops working when the account
      stops being on the tournament;
    * incidents carry the account that logged them, and a photo each at
      most, kept in a table of its own so a list of incidents never drags
      the pictures along;
    * "dispute" is called "complaint" now, which is what the arbiters call
      it.
  """
  use Ecto.Migration

  def change do
    alter table(:tournament_collaborators) do
      add :board_from, :integer
      add :board_to, :integer
    end

    alter table(:mobile_enrollments) do
      add :user_id, references(:users, on_delete: :delete_all)
    end

    create index(:mobile_enrollments, [:user_id])

    alter table(:incidents) do
      add :user_id, references(:users, on_delete: :nilify_all)
      add :has_photo, :boolean, default: false, null: false
    end

    create index(:incidents, [:user_id])

    create table(:incident_photos) do
      add :tournament_id, references(:tournaments, on_delete: :delete_all), null: false
      add :incident_id, references(:incidents, on_delete: :delete_all), null: false
      add :content_type, :string, null: false
      add :byte_size, :integer, null: false
      add :data, :binary, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:incident_photos, [:incident_id])
    create index(:incident_photos, [:tournament_id])

    execute "UPDATE incidents SET kind = 'complaint' WHERE kind = 'dispute'",
            "UPDATE incidents SET kind = 'dispute' WHERE kind = 'complaint'"
  end
end
