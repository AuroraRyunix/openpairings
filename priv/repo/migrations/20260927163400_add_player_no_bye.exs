defmodule PairingsEngine.Repo.Migrations.AddPlayerNoBye do
  @moduledoc """
  "No pairing-allocated bye" per player - an organiser's rule, not a FIDE
  one (docs/pairing-systems.md, "Bye exclusions").

    * `no_bye` - the player must not receive the pairing-allocated bye.
    * `no_bye_rounds` - the rounds it applies to, in `absent_rounds`'
      canonical form ("3,5"); blank means every round.

  Additive and defaulted (off for every existing player), so reversible and
  safe on existing data: nothing pairs differently until somebody ticks it.
  """
  use Ecto.Migration

  def change do
    alter table(:players) do
      add :no_bye, :boolean, null: false, default: false
      add :no_bye_rounds, :string, null: false, default: ""
    end
  end
end
