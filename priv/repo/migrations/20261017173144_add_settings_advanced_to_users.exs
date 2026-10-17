defmodule PairingsEngine.Repo.Migrations.AddSettingsAdvancedToUsers do
  use Ecto.Migration

  # Whether the tournament Settings pages show their advanced settings for
  # this account (`PairingsEngineWeb.SettingsSupport.settings_page/1`). A
  # column beside the stored language, theme and accent rather than browser
  # storage: it is a fact about the arbiter, not about the screen, and it
  # should follow them to the club's laptop. Off for everyone already here.
  def change do
    alter table(:users) do
      add :settings_advanced, :boolean, null: false, default: false
    end
  end
end
