defmodule PairingsEngine.Repo.Migrations.AddMobileEnrollmentClaimedAt do
  use Ecto.Migration

  # One QR/code enrolled UNLIMITED phones until it expired or was revoked - a
  # printed QR left on a table was a working credential for anyone who
  # walked past, and the audit trail recorded the CODE (enrollment_id/code/
  # label), not the device, so three helpers sharing one code were
  # indistinguishable in a dispute about who touched board 12.
  #
  # `claimed_at` makes a code single-device: the first phone to claim it
  # (`Mobile.claim/1`) sets this, and every later attempt through either
  # entry path - the QR token or the 6-digit code, same credential - is
  # refused with a message that says so and sends the helper back to the
  # arbiter for a fresh code (see `MobileEnrollController`).
  #
  # Existing rows get `claimed_at = NULL` - SQLite's own `ADD COLUMN` with
  # no default already does exactly that, so there is nothing to `UPDATE`
  # here - and become single-device from THIS DEPLOY onward: the next phone
  # to use one of them claims it, same as a freshly-minted code. This is
  # deliberately NOT the same call as the `level` backfill
  # (20260904090000_add_mobile_enrollment_level), which moved every existing
  # row to "deputy" so a code already in someone's pocket kept doing exactly
  # what it did yesterday - silently narrowing what a phone could already do,
  # mid-round, would have been invisible to whoever was holding it, and
  # nothing short of hunting the arbiter down would have explained why a tap
  # that used to work suddenly didn't. This refusal is the opposite: the
  # SECOND phone sees a plain message on the spot, and the fix is one tap
  # away for the arbiter (mint another code) - visible and recoverable, so
  # there is no in-progress round to protect by grandfathering old rows in.
  def up do
    alter table(:mobile_enrollments) do
      add :claimed_at, :utc_datetime
    end
  end

  def down do
    alter table(:mobile_enrollments) do
      remove :claimed_at
    end
  end
end
