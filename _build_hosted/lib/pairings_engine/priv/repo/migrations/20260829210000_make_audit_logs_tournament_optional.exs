defmodule PairingsEngine.Repo.Migrations.MakeAuditLogsTournamentOptional do
  @moduledoc """
  Lets an audit-trail row exist without a tournament.

  ## The acts with the widest reach had nowhere to go

  `PairingsEngine.Audit` is an exhaustive record of what happened to a
  tournament, and until now `tournament_id` was `NOT NULL` because every
  audited act was, definitionally, about one. That stopped being true once
  this app grew acts that are about the *installation* instead: a role
  granted or revoked, a backup downloaded, the publishing connection
  repointed or its token replaced, a rating-list sync started. Each is
  arguably a bigger deal than most of what already gets a row - a backup
  download hands over every tournament at once - and each currently reaches
  only `Logger`, which is not a record on a box whose logs rotate.

  ## Why widen this table rather than start a second one

  A machine-wide event and a tournament event are the same kind of fact -
  who did what, when, with what detail - differing only in whether there is
  a tournament to name. Reusing `audit_logs` means one schema, one
  changeset, one write path, and one rendering function
  (`PairingsEngineWeb.AuditLive.describe/1`) for both, rather than a second
  table that has to be kept in step with the first by hand - the same
  reasoning that just moved `parse_absent_rounds/1` out of two private,
  byte-identical copies in `PairingsEngine.Pairing` and `PairingsEngine.Keizer`
  and into one public function on `PairingsEngine.Tournaments.Player`: a rule
  kept in sync by a comment instead of the compiler is a rule that drifts.

  It is also the safer shape for the one thing that must not regress: every
  per-tournament query in `PairingsEngine.Audit` and `AuditLive` filters
  with `WHERE tournament_id = ?`. SQL's null-comparison rule - `NULL = x` is
  never true - means a machine-wide row is excluded from every one of those
  queries automatically, by ordinary equality, rather than by a filter
  someone has to remember to add. A second table would need that
  discipline reasserted at every call site instead of getting it for free.

  ## Why this needs a rebuild rather than `modify`

  SQLite has no `ALTER COLUMN`; ecto_sqlite3 raises immediately on `modify`
  (see `column_change/2` for `:modify` in the adapter). Loosening a
  constraint therefore means SQLite's own recipe: build the table as it
  should now read, copy every row across unchanged, drop the old table,
  rename the new one into its place, and recreate its indexes. Nothing
  about column order, types, defaults or the two foreign keys changes - the
  only difference between the old `CREATE TABLE` and the new one is the
  absence of `NOT NULL` on `tournament_id`. Verified against a copy of a
  real database before this was written: row count, both foreign keys and
  `PRAGMA foreign_key_check` all come back clean after the rebuild.

  `user_id` was already nullable ("System") before this migration, and
  stays exactly as it was.

  ## Down

  Reverses the rebuild the same way, with `tournament_id NOT NULL` again.
  That only succeeds if no machine-wide row exists to violate it - there is
  no tournament to backfill one with - so `down` deletes any row with a
  null `tournament_id` first. Rolling back after this has been running for
  a while therefore discards exactly the rows this migration exists to
  make possible, and only those; every ordinary per-tournament row is
  untouched either way.
  """
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE "audit_logs_new" (
      "id" INTEGER PRIMARY KEY AUTOINCREMENT,
      "tournament_id" INTEGER CONSTRAINT "audit_logs_tournament_id_fkey" REFERENCES "tournaments"("id") ON DELETE CASCADE,
      "user_id" INTEGER CONSTRAINT "audit_logs_user_id_fkey" REFERENCES "users"("id") ON DELETE SET NULL,
      "action" TEXT NOT NULL,
      "details" TEXT DEFAULT ('{}') NOT NULL,
      "inserted_at" TEXT NOT NULL
    )
    """)

    execute("""
    INSERT INTO "audit_logs_new" (id, tournament_id, user_id, action, details, inserted_at)
    SELECT id, tournament_id, user_id, action, details, inserted_at FROM "audit_logs"
    """)

    execute(~s|DROP TABLE "audit_logs"|)
    execute(~s|ALTER TABLE "audit_logs_new" RENAME TO "audit_logs"|)

    create index(:audit_logs, [:tournament_id, :inserted_at])
    create index(:audit_logs, [:tournament_id, :action])
  end

  def down do
    # See the moduledoc: a machine-wide row cannot survive the NOT NULL
    # constraint `down` is about to put back, and there is no tournament to
    # attribute it to instead.
    execute(~s|DELETE FROM "audit_logs" WHERE "tournament_id" IS NULL|)

    execute("""
    CREATE TABLE "audit_logs_new" (
      "id" INTEGER PRIMARY KEY AUTOINCREMENT,
      "tournament_id" INTEGER NOT NULL CONSTRAINT "audit_logs_tournament_id_fkey" REFERENCES "tournaments"("id") ON DELETE CASCADE,
      "user_id" INTEGER CONSTRAINT "audit_logs_user_id_fkey" REFERENCES "users"("id") ON DELETE SET NULL,
      "action" TEXT NOT NULL,
      "details" TEXT DEFAULT ('{}') NOT NULL,
      "inserted_at" TEXT NOT NULL
    )
    """)

    execute("""
    INSERT INTO "audit_logs_new" (id, tournament_id, user_id, action, details, inserted_at)
    SELECT id, tournament_id, user_id, action, details, inserted_at FROM "audit_logs"
    """)

    execute(~s|DROP TABLE "audit_logs"|)
    execute(~s|ALTER TABLE "audit_logs_new" RENAME TO "audit_logs"|)

    create index(:audit_logs, [:tournament_id, :inserted_at])
    create index(:audit_logs, [:tournament_id, :action])
  end
end
