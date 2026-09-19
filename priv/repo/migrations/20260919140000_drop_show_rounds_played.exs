defmodule PairingsEngine.Repo.Migrations.DropShowRoundsPlayed do
  @moduledoc """
  The "Rds" column turned out not to be a tournament setting at all.

  It shipped that morning as `tournaments.show_rounds_played`, first behind a
  checkbox under Settings and then behind a switch on the Standings page. Both
  were wrong: showing a column is a preference of the person looking at the
  table, like every other column tick, and publishing it is the display tick
  that now governs it. Nothing read this field by the time it was dropped, and
  it had been in the world for a few hours - no data is lost that anybody
  entered.
  """
  use Ecto.Migration

  def up do
    alter table(:tournaments) do
      remove :show_rounds_played
    end
  end

  def down do
    alter table(:tournaments) do
      add :show_rounds_played, :boolean, null: false, default: false
    end
  end
end
