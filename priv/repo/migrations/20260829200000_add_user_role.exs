defmodule PairingsEngine.Repo.Migrations.AddUserRole do
  @moduledoc """
  Who may change how this installation is wired up.

  ## What this replaces

  Until now the answer was `PairingsEngine.Accounts.User.sso?/1` - "did this
  person come through 02cloud SSO". That was never the right question, only
  the closest one available: local registration is open to any address
  outside the SSO domain, so `sso?` separated "an account we vouch for" from
  "whoever signed up five minutes ago", and it was pressed into service for
  every privileged action on the Data & sync page.

  Vouching for someone is not the same as making them an administrator.
  Everyone in a federated directory is SSO; almost none of them should be
  able to repoint where an installation publishes, download the entire
  database, or start a rating-list sync. The two questions are now separate
  columns of thought: `keycloak_sub` says how you authenticated, `role` says
  what you may do.

  ## Three values

    * `owner` - an ordinary account. Runs tournaments. The default, and what
      every existing row becomes.
    * `support` - may LOOK. Sees the connection status, the backup list and
      the sync state, and may run the read-only connection check. Changes
      nothing and downloads nothing.
    * `admin` - may change the wiring, and may download a backup.

  `support` exists because the common request is "tell me why publishing
  stopped", and answering it needs sight of the diagnostics rather than the
  authority to alter them. A support role that has to be given admin to be
  useful is not a role, it is a formality.

  ## Nobody is an admin after this runs

  Deliberately. There is no rule that could promote the right people
  automatically - "every SSO account" is exactly the too-broad rule being
  removed, and picking an address here would bake one deployment's operator
  into every other deployment's schema.

  A hosted installation therefore has zero administrators until someone runs
  `mix pairings.role <email> admin` on the box. That is the correct
  bootstrap: shell access on the server is already the highest authority
  there is, so it is the one credential that cannot be circular.

  Local installations are unaffected and need no grant - see
  `PairingsEngine.Authz`, where being able to run the binary is the
  credential.
  """
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :role, :string, default: "owner", null: false
    end

    create index(:users, [:role])
  end

  def down do
    drop index(:users, [:role])

    alter table(:users) do
      remove :role
    end
  end
end
