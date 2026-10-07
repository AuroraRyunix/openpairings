defmodule PairingsEngine.Repo.Migrations.AddMobileEnrollmentLevel do
  use Ecto.Migration

  # "Enrol a phone" has always granted the same thing: full result entry
  # for the whole tournament, every board, every paired round, overwrite
  # included. That is right for a deputy arbiter and too much for "can you
  # hold this and enter the boards near you" - a helper who mis-taps a
  # board that already carries a result had no way to find out from the
  # code that they had just overwritten it, and neither did the arbiter
  # until they happened to notice.
  #
  # `level` narrows what a code may do:
  #
  #   * "helper" - may fill a BLANK board only (never correct one that
  #     already carries a result), on the latest paired round only. The
  #     new default for anything minted from now on - see
  #     `PairingsEngine.Mobile.permit_result/4`.
  #   * "deputy" - today's behaviour, unchanged: any paired round, may
  #     correct an existing result.
  #
  # `board_from`/`board_to` are a separate, orthogonal restriction that
  # applies to both levels: an optional board range, nil/nil meaning every
  # board.
  #
  # Existing rows are backfilled to "deputy" - deliberately NOT the new
  # default. A code already in someone's pocket when this ships must keep
  # doing exactly what it did yesterday; only enrolments minted from now on
  # get the more restricted default. This works in one pass because of
  # SQLite's own ADD COLUMN semantics: `NOT NULL DEFAULT 'helper'` makes
  # every row that exists right now behave as "helper" without rewriting
  # anything on disk, and the UPDATE below then moves exactly those rows -
  # the ones that existed before this migration ran - to "deputy". Any row
  # inserted afterwards (by the application, which always sets `level`
  # explicitly - see `Mobile.create_enrollment/2`) is untouched by that
  # UPDATE and keeps whatever it was given, "helper" if nothing else was
  # asked for.
  def up do
    alter table(:mobile_enrollments) do
      add :level, :string, null: false, default: "helper"
      add :board_from, :integer
      add :board_to, :integer
    end

    execute("UPDATE mobile_enrollments SET level = 'deputy'")
  end

  def down do
    alter table(:mobile_enrollments) do
      remove :level
      remove :board_from
      remove :board_to
    end
  end
end
