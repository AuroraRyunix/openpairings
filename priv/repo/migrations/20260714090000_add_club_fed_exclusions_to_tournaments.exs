defmodule PairingsEngine.Repo.Migrations.AddClubFedExclusionsToTournaments do
  use Ecto.Migration

  # Per-tournament pairing-exclusion rules (SWAR parity #7-10): arbiters
  # often must avoid pairing clubmates / same-federation players against
  # each other. `club_exclusion` / `fed_exclusion` are one of
  # "none" | "all" | "listed"; the matching `_list` column holds a
  # comma-separated, normalized list of club/federation names the "listed"
  # rule applies to (ignored otherwise). See
  # `PairingsEngine.Exclusions` and `docs/forbidden-pairings.md`.
  def change do
    alter table(:tournaments) do
      add :club_exclusion, :string, null: false, default: "none"
      add :club_exclusion_list, :string, null: false, default: ""
      add :fed_exclusion, :string, null: false, default: "none"
      add :fed_exclusion_list, :string, null: false, default: ""
    end
  end
end
