defmodule PairingsEngine.Repo.Migrations.AddLateEntryAbsences do
  @moduledoc """
  "Rounds before a late entrant joins count as absences"
  (`tournaments.late_entry_absences`, see `PairingsEngine.LateEntry`).

  On by default, and on for every existing tournament that is still being
  played: it only does anything in a Swiss tournament that pays points for
  an absence (`abs_value` > 0), and those are meant to get the new
  behaviour. Nothing is written anywhere else - the rounds before a
  player's join round are scored as absences when standings are read, not
  stored as rows.

  Off for a tournament that is already over - finished (`status`
  "finished": every round paired and scored) or archived - so upgrading
  does not quietly rewrite the final standings of an event whose prizes
  were handed out under the old count. Its organiser can switch it on
  (Settings, Scoring) if that is what they want.

  Additive and defaulted, so reversible and safe on existing data.
  """
  use Ecto.Migration

  def up do
    alter table(:tournaments) do
      add :late_entry_absences, :boolean, null: false, default: true
    end

    flush()

    execute(finished_off_sql())
  end

  @doc """
  The statement that leaves finished and archived tournaments as they
  were - public so `test/pairings_engine/late_entry_migration_test.exs`
  runs exactly this text against rows of its own.
  """
  def finished_off_sql do
    """
    UPDATE tournaments
       SET late_entry_absences = 0
     WHERE status = 'finished' OR archived_at IS NOT NULL
    """
  end

  def down do
    alter table(:tournaments) do
      remove :late_entry_absences
    end
  end
end
