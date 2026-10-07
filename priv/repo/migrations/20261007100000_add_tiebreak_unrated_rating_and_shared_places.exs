defmodule PairingsEngine.Repo.Migrations.AddTiebreakUnratedRatingAndSharedPlaces do
  @moduledoc """
  `tournaments.tiebreak_unrated_rating` - what an unrated player counts as in
  the rating-based tie-breaks (null: C.07 Article 10's drop) - and
  `tournaments.shared_places` - whether players level after the whole
  tie-break list share a place. Both leave every existing tournament's
  standings as they were.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :tiebreak_unrated_rating, :integer
      add :shared_places, :boolean, null: false, default: false
    end
  end
end
