defmodule PairingsEngine.Repo.Migrations.AddRegistrationSettings do
  @moduledoc """
  The entry form's own settings: when it opens and closes, how big the field
  is, and whether the results site may list who has entered.

  All four only reach anybody by riding along in the published snapshot
  (`tournament.registration`, see OpenResults' `docs/snapshot-schema.md`),
  exactly like `registration_open` beside them. None of them opens the form:
  that is still `registration_open`, off by default.

  Every column is nullable or defaults to "no restriction" / "not listed",
  so an existing tournament reads exactly as it did before.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :registration_opens_at, :utc_datetime
      add :registration_closes_at, :utc_datetime
      add :registration_max_players, :integer
      add :registration_list_public, :boolean, default: false, null: false
    end
  end
end
