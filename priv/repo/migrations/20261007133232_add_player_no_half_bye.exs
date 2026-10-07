defmodule PairingsEngine.Repo.Migrations.AddPlayerNoHalfBye do
  @moduledoc """
  "Not eligible for half-point byes" on a player: C.05:6.7.4 keeps the
  half-point bye from players who got conditions or free entry, so the arbiter
  can mark them and the app refuses to give them one.
  """
  use Ecto.Migration

  def change do
    alter table(:players) do
      add :no_half_bye, :boolean, null: false, default: false
    end
  end
end
