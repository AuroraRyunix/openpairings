defmodule PairingsEngine.Repo.Migrations.AddPublicHallToTournaments do
  use Ecto.Migration

  # How the results site's hall display (the full-screen page on a TV or
  # projector in the playing hall) runs for this tournament: which views it
  # cycles through, how long each stays up, and the arbiter's announcement.
  #
  # Nil means every default - see `PairingsEngine.HallDisplay`. Display
  # preferences only: what the public may see at all is still `public_display`
  # and each round's level.
  def change do
    alter table(:tournaments) do
      add :public_hall, :map
    end
  end
end
