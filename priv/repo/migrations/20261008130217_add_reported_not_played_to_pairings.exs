defmodule PairingsEngine.Repo.Migrations.AddReportedNotPlayedToPairings do
  @moduledoc """
  `pairings.not_played_at`: when the arbiter recorded an open postponed
  game as "not played in this event" (VCL4THP Q169,
  `PairingsEngine.PostponedGames.report_not_played/2`). In FIDE mode no TRF
  and no final standings are produced while a postponed game is open and
  carries no such record; recording one takes the tournament out of FIDE
  mode. The board keeps its postponed result, so a game played later still
  goes in the postponed-games file. Nullable, no backfill: no game was ever
  recorded that way before this column existed.
  """
  use Ecto.Migration

  def change do
    alter table(:pairings) do
      add :not_played_at, :utc_datetime
    end
  end
end
