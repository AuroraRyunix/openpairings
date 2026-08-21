defmodule PairingsEngine.Repo.Migrations.AddTournamentsSwarGuid do
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      # SWAR's own per-tournament GUID (from the .swar file's header, see
      # PairingsEngine.SwarImport.parse/1's `:guid` key) - SWAR's own
      # "upload to server" feature re-sends the same GUID on every re-upload
      # of the same tournament, so it's the stable "same tournament" identity
      # a fresh .swar upload can be matched against, to warn before creating
      # an accidental duplicate rather than silently doing so. nil for
      # tournaments never imported from SWAR, or imported before this field
      # existed.
      add :swar_guid, :string
    end

    create index(:tournaments, [:user_id, :swar_guid])
  end
end
