defmodule PairingsEngine.Repo.Migrations.AddPublishStartingRank do
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      # Whether the snapshot may publish the entry list before round 1 has
      # results - see `Tournament`'s own field doc. Default true: existing
      # tournaments keep showing OpenResults' "Starting rank" exactly as
      # they always have, and only an arbiter who deliberately turns it off
      # gets the roster withheld until round 1's results are in.
      add :publish_starting_rank, :boolean, null: false, default: true
    end
  end
end
