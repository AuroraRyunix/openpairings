defmodule PairingsEngine.Repo.Migrations.AddOpenresultsRemovedAtToTournaments do
  use Ecto.Migration

  # When the results site answered `tournament_deleted`: its operator deleted
  # this tournament there, and publishing was switched off here so the queue
  # stops asking. Cleared when the arbiter switches publishing on again. See
  # `PairingsEngine.Publishing`, "Removed by the results site".
  def change do
    alter table(:tournaments) do
      add :openresults_removed_at, :utc_datetime
    end
  end
end
