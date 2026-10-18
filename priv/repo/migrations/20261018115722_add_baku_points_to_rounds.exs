defmodule PairingsEngine.Repo.Migrations.AddBakuPointsToRounds do
  @moduledoc """
  `rounds.baku_points` - the Baku virtual points (C.04.7 1.4) each player
  was paired with in that round, `%{"player id" => points}`, one entry
  for every player holding a pairing number (0.0 in Group B). Recorded when
  the round is paired, like `rounds.virtual_points` is for extra points,
  because they used to be worked out again on every run from today's
  `rounds_count`, `acceleration` and pairing numbers, and those can change
  after the round was played.

  Nil for every round that existed before this column, and for every round
  of a tournament without Baku: those rounds are worked out as before
  (`PairingsEngine.Pairing.accelerations/3`).
  """
  use Ecto.Migration

  def change do
    alter table(:rounds) do
      add :baku_points, :map
    end
  end
end
