defmodule PairingsEngine.Repo.Migrations.AddTournamentsPresenceValue do
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      # SWAR "3-2-1" custom-scoring `SW321_Pre` ("presence points", manual
      # §4.6 field 84) - the points paid for an unpaired-but-present round
      # (SWAR's LOST_BYE / our byes.type == "requested-zero"), which is a
      # distinct value from an ordinary configured loss even though SWAR's
      # own result-code bitmask (§5.2) files LOST_BYE under its generic
      # "loss" category. Nullable/no default is intentional: nil means "not
      # set" and every non-3-2-1-import tournament must keep falling back to
      # `points_loss` exactly as before. Only PairingsEngine.SwarImport
      # writes a non-nil value here (type=3 imports).
      add :presence_value, :float
    end
  end
end
