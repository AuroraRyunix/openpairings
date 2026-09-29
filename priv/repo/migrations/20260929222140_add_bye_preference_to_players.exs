defmodule PairingsEngine.Repo.Migrations.AddByePreferenceToPlayers do
  @moduledoc """
  A per-player preference for the pairing-allocated bye - an organiser's
  wish, not a FIDE rule (docs/pairing-systems.md, "Bye preferences").

    * `bye_preference` - "" (none), "want_hard" (must get it), "want_soft"
      (rather gets it) or "avoid_soft" (rather not). The fourth setting,
      "must not get it", is the existing `no_bye` bye exclusion and stays
      in its own columns.
    * `bye_preference_rounds` - the rounds it applies to, in
      `absent_rounds`' canonical form ("3,5"); blank means every round.

  Additive and defaulted (none for every existing player), so reversible
  and safe on existing data: nothing pairs differently until somebody sets
  one.
  """
  use Ecto.Migration

  def change do
    alter table(:players) do
      add :bye_preference, :string, null: false, default: ""
      add :bye_preference_rounds, :string, null: false, default: ""
    end
  end
end
