defmodule PairingsEngine.Repo.Migrations.AddTournamentsAbsJusqueAndNbfois do
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      # SWAR `AbsJusque` (manual §4.2 field 92 group, "Jusque ronde": the
      # last round, INCLUSIVE, an absence still pays `abs_value" — beyond
      # it a plain absence scores `points_loss` instead, same as if
      # `abs_value` were unset). Nullable/no default: nil means "no round
      # cap", matching every tournament that predates this field. Only
      # PairingsEngine.SwarImport writes a non-nil value.
      add :abs_jusque, :integer
      # SWAR `AbsNbFois` (manual §4.2 field 92 group, "Nombre de fois": how
      # many absences, cumulative across the tournament so far, still pay
      # `abs_value` — the (N+1)th and any later absence score
      # `points_loss` instead). Nullable/no default, same reasoning as
      # `abs_jusque` above.
      add :abs_nbfois, :integer
    end
  end
end
