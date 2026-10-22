defmodule PairingsEngine.Repo.Migrations.AddRegistrationsCheckedAtToTournaments do
  use Ecto.Migration

  # When entries were last fetched from the results site, by the button or
  # by the timer. It lived in the Entries page's socket, so every visit
  # began with no idea when anyone last looked.
  def change do
    alter table(:tournaments) do
      add :registrations_checked_at, :utc_datetime
    end
  end
end
