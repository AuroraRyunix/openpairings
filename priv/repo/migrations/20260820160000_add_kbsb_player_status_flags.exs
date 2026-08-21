defmodule PairingsEngine.Repo.Migrations.AddKbsbPlayerStatusFlags do
  use Ecto.Migration

  # The data platform's roster export is deliberately unfiltered - it carries
  # archived, deceased and non-affiliated members alongside everyone else -
  # because filtering it would make its `?since=` incremental mode unsound: a
  # row dropping out of a filter is indistinguishable from a row that did not
  # change, so an incremental mirror would keep a stale copy forever.
  #
  # That is the right call on their side, and it means the decision moves
  # here. Storing the two flags rather than dropping the rows at import keeps
  # the mirror faithful to the source and lets each caller decide: an exact
  # id match should still resolve a deceased member (an arbiter looking up a
  # matricule wants an answer), while a fuzzy NAME match must not, or a
  # living player can inherit a dead namesake's club.
  #
  # Nullable, with no default: a row from the older file-upload path has no
  # opinion on either flag, and `nil` says that honestly rather than
  # asserting "alive and affiliated" on data that never mentioned it.
  def change do
    alter table(:kbsb_players) do
      add :died, :boolean
      add :affiliated, :boolean
    end
  end
end
