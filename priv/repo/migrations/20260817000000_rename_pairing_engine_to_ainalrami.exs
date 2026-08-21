defmodule PairingsEngine.Repo.Migrations.RenamePairingEngineToAinalrami do
  use Ecto.Migration

  # The sibling Dutch engine was renamed from "OpenPair" to "Ainalrami".
  #
  # `tournaments.pairing_engine` stores that name as a plain string, so the
  # rename is a DATA change, not just a code one: without this, every
  # tournament already opted into the beta engine would hold a value the
  # changeset's `validate_inclusion` no longer accepts. They would keep
  # pairing (the value is only re-validated on write), but the next edit of
  # any field on that tournament would fail validation on a column the user
  # never touched, and the settings dropdown would render no selection.
  #
  # Narrow by construction: `WHERE pairing_engine = 'openpair'` touches
  # nothing else, and "javafo" rows - the default, and the overwhelming
  # majority - are not read or written at all.
  def up do
    execute "UPDATE tournaments SET pairing_engine = 'ainalrami' WHERE pairing_engine = 'openpair'"
  end

  # Reversible, because the only thing standing between a stored value and
  # the code that validates it is this migration: rolling the schema back
  # past it without restoring the old value would strand exactly the rows
  # `up/0` fixed, in the same way and for the same reason.
  def down do
    execute "UPDATE tournaments SET pairing_engine = 'openpair' WHERE pairing_engine = 'ainalrami'"
  end
end
