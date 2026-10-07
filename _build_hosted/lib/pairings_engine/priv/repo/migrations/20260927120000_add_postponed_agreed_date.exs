defmodule PairingsEngine.Repo.Migrations.AddPostponedAgreedDate do
  @moduledoc """
  The date two players agreed to play a postponed game on
  (`PairingsEngine.PostponedGames`), and the short record of how that date
  changed.

    * `agreed_date` - optional, nil for every existing row. Not a deadline:
      nothing becomes overdue when it passes, it is only what the players
      said, for the notice, the calendar file and the results site.
    * `agreed_date_log` - one `%{"from", "to", "at", "by"}` entry per change,
      oldest first, so the arbiter can see who moved the game and when.

  Additive, nullable or defaulted, so reversible and safe on existing data.
  """
  use Ecto.Migration

  def change do
    alter table(:pairings) do
      add :agreed_date, :date
      add :agreed_date_log, {:array, :map}, null: false, default: []
    end
  end
end
