defmodule PairingsEngine.Repo.Migrations.AddPostponedReportAndCopyConfirmation do
  @moduledoc """
  Two things for sending results (the postponed-games audit of 2026-10-01):

    * `postponed_report_name` and `postponed_fide_tournament_id` - the
      postponed-games file is reported to FIDE as a tournament of its own
      ("Clubkampioenschap 25-26 uitgestelde partijen"), with its own name
      and its own FIDE tournament ID, separate from the main event's. nil
      name = the default (the event's name + "postponed games"); nil ID =
      none set yet.
    * `send_confirmation_needed` - set on a tournament imported from a file
      (a JSON backup, a TRF, a `.swar`) of an event that may already have
      been reported from somewhere else: what kind of file it came from.
      While it is set, nothing can be sent from this copy; an arbiter
      clears it by confirming, on the Export page, that this copy is the
      one that reports. Never cleared by anything else.

  Columns only; every existing tournament keeps sending as it did.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :postponed_report_name, :string
      add :postponed_fide_tournament_id, :string
      add :send_confirmation_needed, :string
    end
  end
end
