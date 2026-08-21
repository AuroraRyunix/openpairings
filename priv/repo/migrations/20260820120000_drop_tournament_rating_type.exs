defmodule PairingsEngine.Repo.Migrations.DropTournamentRatingType do
  use Ecto.Migration

  # `rating_type` was a "Pair by: FIDE rating / National rating" select on
  # the tournament options page. It was stored, validated and exported, but
  # never read: pairing order comes from `Tournaments.Player.rating/1`,
  # which is unconditionally FIDE-first-national-fallback and never
  # consulted this column. Switching it to "National rating" therefore
  # changed nothing at all, which is worse than not offering the choice.
  #
  # Dropping the column loses no information - every row's value was inert.
  def up do
    alter table(:tournaments) do
      remove :rating_type
    end
  end

  def down do
    alter table(:tournaments) do
      add :rating_type, :string, default: "fide"
    end
  end
end
