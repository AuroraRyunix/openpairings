defmodule PairingsEngine.Repo.Migrations.AddLateEntryAbsences do
  @moduledoc """
  "Rounds before a late entrant joins count as absences"
  (`tournaments.late_entry_absences`, see `PairingsEngine.LateEntry`).

  On by default, and on for every existing tournament: it only does
  anything in a Swiss tournament that pays points for an absence
  (`abs_value` > 0), and those are meant to get the new behaviour. Nothing
  is written anywhere else - the rounds before a player's `start_round`
  are scored as absences when standings are read, not stored as rows.

  Additive and defaulted, so reversible and safe on existing data.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :late_entry_absences, :boolean, null: false, default: true
    end
  end
end
