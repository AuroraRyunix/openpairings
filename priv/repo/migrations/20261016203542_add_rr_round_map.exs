defmodule PairingsEngine.Repo.Migrations.AddRrRoundMap do
  @moduledoc """
  `tournaments.rr_round_map`: which Berger table round each played round of
  a round robin is, after the arbiter swapped rounds
  (`PairingsEngine.RoundSwap`). Null - every tournament so far - is the
  table's own order.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :rr_round_map, {:array, :integer}
    end
  end
end
