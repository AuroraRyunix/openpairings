defmodule PairingsEngine.Repo.Migrations.AddTournamentPairingEngine do
  use Ecto.Migration

  # WHICH Swiss engine pairs a round — distinct from `pairing_system`, which
  # decides WHETHER the Swiss path runs at all (round robin and Keizer never
  # reach an engine; see PairingsEngine.Pairing.pair_next_round/1).
  #
  # "javafo" (the default) is the only value that existed before this column,
  # so the default alone is the whole backfill: every existing tournament
  # keeps pairing exactly as it did, byte for byte. "openpair" is the opt-in
  # beta alternative (github.com/AuroraRyunix/openpair).
  #
  # The value is NOT validated in the database (SQLite has no enum, and this
  # project's other closed vocabularies — pairing_system, publish_mode,
  # acceleration — are all plain strings validated in the changeset). The two
  # rules that actually matter are enforced there too, deliberately in the
  # data layer rather than the UI: "openpair" is refused on a
  # FIDE-homologated tournament (in both directions), and the column joins
  # `Tournaments.locked_fields/1` once round 1 is paired, because switching
  # engines mid-event would reinterpret rounds already on the board.
  def change do
    alter table(:tournaments) do
      # javafo | openpair
      add :pairing_engine, :string, null: false, default: "javafo"
    end
  end
end
