defmodule PairingsEngine.Repo.Migrations.AddTournamentsAbsValue do
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      # SWAR `AbsValue` (manual §4.2 field 92: "Absent value: 0 or 5,
      # representing 0.0 or 0.5 points") - the points paid for a player
      # simply marked ABSENT for a round (our `byes`-table `type: "absent"`
      # row). Distinct from `bye_value` (a pairing-allocated bye's value)
      # and `presence_value` (3-2-1 "presence points", type==3 only) -
      # `abs_value` is a general [TOURNOI] header field, unconditional on
      # tournament type. Nullable/no default is intentional: nil means "not
      # set" and every non-SWAR-import tournament must keep falling back to
      # `points_loss` exactly as before. Only PairingsEngine.SwarImport
      # writes a non-nil value here.
      add :abs_value, :float
    end
  end
end
