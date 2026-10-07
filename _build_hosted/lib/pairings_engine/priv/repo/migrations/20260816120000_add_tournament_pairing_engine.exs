defmodule PairingsEngine.Repo.Migrations.AddTournamentPairingEngine do
  use Ecto.Migration

  # WHICH Swiss engine pairs a round - distinct from `pairing_system`, which
  # decides WHETHER the Swiss path runs at all (round robin and Keizer never
  # reach an engine; see PairingsEngine.Pairing.pair_next_round/1).
  #
  # "javafo" (the default) is the only value that existed before this column,
  # so the default alone is the whole backfill: every existing tournament
  # keeps pairing exactly as it did, byte for byte. The second value is the
  # opt-in beta alternative, the sibling from-scratch Elixir Dutch engine.
  #
  # That engine was renamed after this migration ran, so the value this
  # migration introduced is NOT the one the code uses today - see
  # 20260817T000000_rename_pairing_engine_to_ainalrami.exs, which carries
  # existing rows across. Deliberately not restated here: an applied
  # migration should record what it did, not what became true later.
  #
  # The value is NOT validated in the database (SQLite has no enum, and this
  # project's other closed vocabularies - pairing_system, publish_mode,
  # acceleration - are all plain strings validated in the changeset). The two
  # rules that actually matter are enforced there too, deliberately in the
  # data layer rather than the UI: the beta engine is refused on a
  # FIDE-homologated tournament (in both directions), and the column joins
  # `Tournaments.locked_fields/1` once round 1 is paired, because switching
  # engines mid-event would reinterpret rounds already on the board.
  def change do
    alter table(:tournaments) do
      add :pairing_engine, :string, null: false, default: "javafo"
    end
  end
end
