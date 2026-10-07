defmodule PairingsEngine.Repo.Migrations.AddFideComplianceLostRound do
  @moduledoc """
  The one thing about FIDE-mode compliance that has to be stored.

  Compliance itself is DERIVED - `PairingsEngine.Compliance.check/1` reads a
  tournament's settings and says whether they still describe a FIDE-handled
  event. Nothing about that needs a column, and giving it one would create
  the second FIDE-ish tickbox `docs/design-fide-mode.md` section 0c says not
  to have.

  What cannot be derived is WHEN. VCL4THP asks for a `###` TRF comment
  naming the round in which the mode was left, and once an arbiter has put
  the setting back - or simply moved on three rounds - nothing in the data
  can reconstruct which round it was. So this column, and only this column.

  `nil` means "compliance has never been lost". `0` is a real value and
  means "lost before any round was paired" - a Keizer tournament is
  non-compliant from the moment it is created, which is not the same as
  never having lost it. That is why the column is nullable rather than
  defaulting to a sentinel.

  Existing rows backfill to `nil`, which claims every tournament already in
  the database was handled compliantly. That is unprovable, and it is still
  the right answer: the alternative (`0` for everything) puts a `###` line
  in the re-export of every past event on the grounds that this software
  was not watching at the time. The mode is a statement about how the
  program behaves from here, not a verdict on rounds already paired.

  Deliberately NOT cast by `Tournament.changeset/2`: an ordinary settings
  save must not be able to write - or, far worse, clear - a fact about this
  tournament's history. `Tournaments` stamps it inside the same changeset as
  the save that causes it, and `TournamentImport` carries it across
  explicitly. Same mechanism, and the same reasoning, as
  `manual_ranking_stale` and `openresults_key`.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :fide_compliance_lost_round, :integer
    end
  end
end
