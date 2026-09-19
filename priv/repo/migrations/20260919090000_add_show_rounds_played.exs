defmodule PairingsEngine.Repo.Migrations.AddShowRoundsPlayed do
  @moduledoc """
  The standings column that counts the rounds a player was present for, byes
  included - for club championships that give a prize for attending them all.

  Off for every existing tournament, which is what `default: false` gives: a
  column nobody asked for must not appear on a standings sheet mid-event.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :show_rounds_played, :boolean, null: false, default: false
    end
  end
end
