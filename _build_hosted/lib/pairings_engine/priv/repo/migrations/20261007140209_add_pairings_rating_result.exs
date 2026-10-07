defmodule PairingsEngine.Repo.Migrations.AddPairingsRatingResult do
  @moduledoc """
  `pairings.rating_result` - a result corrected for the rating report only
  (C.04.2:4.3, VCL4THP Q192): a wrong result found after the next round was
  over keeps its original `result` for the pairings and the standings, and
  the corrected one goes into the report sent for rating. Nil for every
  board never so corrected.
  """
  use Ecto.Migration

  def change do
    alter table(:pairings) do
      add :rating_result, :string
    end
  end
end
