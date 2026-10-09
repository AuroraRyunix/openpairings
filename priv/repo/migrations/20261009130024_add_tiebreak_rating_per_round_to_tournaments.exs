defmodule PairingsEngine.Repo.Migrations.AddTiebreakRatingPerRoundToTournaments do
  @moduledoc """
  `tournaments.tiebreak_rating_per_round`: for a tournament lasting more
  than 30 days, the rating-based tie-breaks count each opponent at the
  rating they held in the round the game was played (VCL4THP Q214). Off -
  the default, and every tournament that exists - they use one rating per
  player, the first, as C.07 Article 10 prescribes unless the regulations
  say otherwise.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :tiebreak_rating_per_round, :boolean, null: false, default: false
    end
  end
end
