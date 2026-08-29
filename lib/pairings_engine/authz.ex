defmodule PairingsEngine.Authz do
  @moduledoc """
  Who may change how this installation is wired up.

  One module, because the answer differs between a hosted deployment and an
  arbiter's laptop and that difference must be stated once. Every gate on
  the Data & sync page and the backup download reads these two functions.

  ## The rule

  **Hosted**: an explicit `admin` role, granted by someone with shell access
  on the box (`mix pairings.role`), or an address the deployment declares in
  `ADMIN_EMAILS`. Not "signed in", not "signed in through SSO" - those say
  how somebody authenticated, which is a different question from what they
  may do. Answering the second with the first is what this replaces: it made
  every account in a federated directory an administrator of the publishing
  configuration.

  The two routes carry the same authority because they need the same thing
  to use: root on the server. `ADMIN_EMAILS` is read from the systemd unit,
  which is written `chmod 600`, and anyone who can edit it could run the
  mix task instead. It exists so a hosted installation has an administrator
  the moment it boots rather than after somebody remembers a manual step -
  and it declares rather than promotes, so a restart cannot silently undo a
  deliberate demotion.

  **Local**: everyone, because there is no one else. A local run is not a
  smaller server with laxer rules; it is a different thing, and the
  difference is structural rather than a judgement call about risk.

  ## Why local mode needs no role

  A local installation has no accounts. `PairingsEngineWeb.UserAuth`
  auto-signs-in a synthetic owner (`Accounts.local_owner!/0`, an address
  built from the OS user at this machine's hostname), and two independent
  conditions must both hold before it will: `:local_mode` is set, which only
  `config/runtime.exs` does, and **the request came from loopback**, checked
  per request against `conn.remote_ip` rather than the attacker-controlled
  `X-Forwarded-For`. Local mode also pins the listener to 127.0.0.1.

  So the person at the keyboard is the only person who can reach the page at
  all, and they already have the database file, the generated secret beside
  it, and the binary. Being able to run it IS the credential - the same
  reasoning `User.local_owner_changeset/2` gives for skipping email
  confirmation, and for the same reason: there is nothing to confirm and
  nobody to confirm it to.

  Requiring a role there would not add a check. It would remove a feature:
  an arbiter would be locked out of setting where their own laptop
  publishes, syncing the rating list, and taking a backup, with no way to
  grant themselves the role short of a mix task on their own machine. Which
  is precisely what shipped by accident and is fixed here - see the note in
  `CHANGELOG.md` for 0.17.2.

  ## What `support` may do

  Look, not touch. The connection status, the backup list, the sync state,
  and the read-only connection check - enough to answer "why did publishing
  stop" without the authority to alter the answer. It may NOT download a
  backup: that is the whole database, every player, the one piece of
  personal data in the system (the addresses people gave the entry form),
  and every OpenResults publishing key.
  """

  alias PairingsEngine.Accounts.User

  @doc """
  Whether `user` may change the publishing connection, run or download a
  backup, and start a rating-list sync.

  True for anyone on a local installation, for anyone holding the `admin`
  role, and for anyone the deployment declares in `ADMIN_EMAILS`. See the
  moduledoc.
  """
  def may_administer?(user), do: local_mode?() or User.admin?(user) or declared_admin?(user)

  @doc """
  Whether `user` may see the diagnostics and run the read-only connection
  check.

  Implied by `may_administer?/1`.
  """
  def may_support?(user), do: may_administer?(user) or User.support?(user)

  @doc """
  The addresses this deployment declares as administrators, lower-cased.

  Set from `ADMIN_EMAILS` in `config/runtime.exs`; see the comment there for
  why declaring beats promoting.
  """
  def declared_admin_emails, do: Application.get_env(:pairings_engine, :admin_emails, [])

  # Case-insensitively on BOTH sides, because an address is not
  # case-sensitive in practice and an operator who typed a capital - in the
  # unit file or when the account was made - should not spend an evening
  # working out why the page still refuses them.
  #
  # `config/runtime.exs` already lower-cases what it parses, so this is
  # belt and braces there. It is not redundant: the config key is plain
  # application environment, and anything else that ever sets it would
  # otherwise fail this check in a way nothing would explain.
  defp declared_admin?(%User{email: email}) when is_binary(email) do
    wanted = String.downcase(email)
    Enum.any?(declared_admin_emails(), &(String.downcase(&1) == wanted))
  end

  defp declared_admin?(_), do: false

  @doc """
  Whether this is a local run.

  The canonical reader. `config/runtime.exs` sets the flag once at boot from
  `OPENPAIRINGS_LOCAL`, and everything that needs the answer asks here, so
  "is this a local run" has one answer AND one place that reads it.
  """
  def local_mode?, do: Application.get_env(:pairings_engine, :local_mode, false) == true
end
