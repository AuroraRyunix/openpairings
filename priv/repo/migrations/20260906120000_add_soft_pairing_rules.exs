defmodule PairingsEngine.Repo.Migrations.AddSoftPairingRules do
  @moduledoc """
  Soft pairing rules - wishes the Swiss engine weighs against the pairing
  criteria, as opposed to the rules it must satisfy.

  A forbidden pairing has always been a rule: an `XXP` line the engine may
  not cross. `forbidden_pairings.soft` marks a row as the other thing an
  arbiter often means - "keep these two apart if you can, but do not break
  the pairing over it". A soft row is never written to the TRF; it goes to
  Ainalrami as a `:soft_pairs` option, a rung of its own on the criteria
  ladder (see `PairingsEngine.Pairing.soft_pairs/5`).

  `tournaments.soft_club_rounds` is the same wish for whole clubs, for the
  first N rounds only - the classic "no clubmates in rounds one and two".
  `tournaments.soft_position` says how hard every soft wish is tried:
  "strong" sits above the quality criteria (the engine would rather float a
  player than seat the pair), "weak" is a tie-break and nothing more.

  All three default to "no soft rules", under which the engine's behaviour
  is byte for byte what it was. JaVaFo and Keizer have no such option and
  ignore soft rules; the Settings page says so beside the controls.
  """
  use Ecto.Migration

  def change do
    alter table(:forbidden_pairings) do
      add :soft, :boolean, default: false, null: false
    end

    alter table(:tournaments) do
      add :soft_club_rounds, :integer, default: 0, null: false
      add :soft_position, :string, default: "strong", null: false
    end
  end
end
