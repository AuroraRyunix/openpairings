defmodule PairingsEngine.Repo.Migrations.UniqueActiveEnrollmentCode do
  use Ecto.Migration

  # `code` was indexed but not uniquely, and uniqueness was enforced by
  # `Mobile.gen_unique_code/1` reading the table and then inserting - a race
  # with itself, and one that GAVE UP after twenty attempts and returned a
  # possibly-duplicate code anyway. Two active enrollments sharing a code
  # then made `get_active_by_code/1`'s `Repo.one` raise
  # `Ecto.MultipleResultsError`, straight through the public `POST /m` with
  # nothing on the path to rescue it.
  #
  # A partial unique index is the honest place for the rule. It is keyed on
  # `revoked_at IS NULL` rather than on "active" (which also means
  # `expires_at > now`), because an index predicate cannot mention the
  # current time. That is the STRICTER of the two: an expired but
  # un-revoked row keeps its code reserved. With eight digits (90 million
  # codes) and a retry on collision that costs nothing worth measuring, and
  # it is the direction to err in - a stale row holding a code back is
  # harmless, two live rows sharing one is the bug.
  #
  # Existing rows are made to fit before the index is built. Any group of
  # un-revoked rows sharing a code keeps the newest and the rest are
  # revoked: they were already unreachable in practice (the read that found
  # them raised), and revoking is what an arbiter would have done to them.
  def up do
    execute("""
    UPDATE mobile_enrollments
       SET revoked_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
     WHERE revoked_at IS NULL
       AND id NOT IN (
             SELECT MAX(id)
               FROM mobile_enrollments
              WHERE revoked_at IS NULL
              GROUP BY code
           )
    """)

    create unique_index(:mobile_enrollments, [:code],
             where: "revoked_at IS NULL",
             name: :mobile_enrollments_active_code_index
           )
  end

  def down do
    drop index(:mobile_enrollments, [:code], name: :mobile_enrollments_active_code_index)
  end
end
