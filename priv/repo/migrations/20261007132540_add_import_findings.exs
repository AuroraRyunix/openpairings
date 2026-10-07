defmodule PairingsEngine.Repo.Migrations.AddImportFindings do
  @moduledoc """
  `tournaments.import_findings`: what a TRF import changed to fit the file,
  which TRF version it read, and the rounds of the file that broke a
  pairing rule - an Import PIBE in the TEC manual's terms - kept with the
  tournament the import created (`PairingsEngine.TrfImport.findings/1`).

  Nil for every existing tournament, and for every tournament not made by
  a TRF import.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :import_findings, :map
    end
  end
end
