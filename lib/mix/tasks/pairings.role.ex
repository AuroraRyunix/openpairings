defmodule Mix.Tasks.Pairings.Role do
  @shortdoc "Grant or revoke an administrator or support role"

  @moduledoc """
  Who may change how this installation is wired up.

      mix pairings.role                        # who currently holds a role
      mix pairings.role someone@example.com admin
      mix pairings.role someone@example.com support
      mix pairings.role someone@example.com owner    # revoke

  ## Why this is a command line and not a screen

  A hosted installation has **no administrators until this is run**. That is
  deliberate and it is the whole design: there is no rule that could promote
  the right people automatically, because "everyone who signed in through
  SSO" is exactly the too-broad rule the role replaces.

  Shell access on the box is already the highest authority there is - it can
  read the database, the secrets and the backups directly - so making it the
  way roles are granted keeps the authority to grant admin from being
  something admin itself confers. A screen would mean the first administrator
  had to come from somewhere else anyway, and every later one could be
  created by whoever got in first.

  Local installations need none of this. See `PairingsEngine.Authz`.

  ## The Repo, and only the Repo

  `@requirements` is `app.config` and the Repo is started by hand for the
  same reason `mix pairings.backup` avoids `app.start`: starting the whole
  application brings up a second web endpoint against the port the live
  service is already bound to. A task that changes one row should not be able
  to disturb a running tournament.
  """
  use Mix.Task

  alias PairingsEngine.Accounts
  alias PairingsEngine.Accounts.User
  alias PairingsEngine.Authz

  @requirements ["app.config"]

  @impl Mix.Task
  def run(argv) do
    start_repo()

    case argv do
      [] -> list()
      [email, role] when role in ~w(owner support admin) -> set(email, role)
      [_email, role] -> Mix.raise("unknown role #{inspect(role)}: expected one of #{roles()}")
      _ -> Mix.raise("usage: mix pairings.role [EMAIL #{roles()}]")
    end
  end

  defp roles, do: Enum.join(User.roles(), " | ")

  defp start_repo do
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = PairingsEngine.Repo.start_link(pool_size: 1)
  end

  defp list do
    users = Accounts.privileged_users()
    declared = Authz.declared_admin_emails()

    # Declared administrators are listed too, and marked. They hold no row,
    # so a listing that showed only the database would say "nobody" on an
    # installation that has a working administrator - which is exactly the
    # sort of wrong answer somebody acts on at midnight.
    if users == [] and declared == [] do
      Mix.shell().info([
        :yellow,
        "Nobody holds a role on this installation.\n",
        :reset,
        "Publishing settings, backups and rating syncs cannot be changed until\n",
        "somebody does. Grant one with:\n\n",
        "    mix pairings.role you@example.com admin\n"
      ])
    else
      Mix.shell().info("")

      for user <- users do
        Mix.shell().info([pad(user.role), :reset, "  ", user.email])
      end

      for email <- declared do
        Mix.shell().info([pad("admin"), :reset, "  ", email, :yellow, "  (ADMIN_EMAILS)", :reset])
      end

      if declared != [] do
        Mix.shell().info([
          "\n",
          :yellow,
          "Addresses marked (ADMIN_EMAILS) are declared by this deployment's\n",
          "configuration, not by a role in the database. Remove them from the\n",
          "systemd unit to revoke - this task cannot.\n",
          :reset
        ])
      end

      Mix.shell().info("")
    end
  end

  # Colour carries the same information as the word beside it rather than
  # replacing it - the word is what a log or a pipe keeps.
  defp pad("admin"), do: [:red, String.pad_trailing("admin", 8)]
  defp pad("support"), do: [:cyan, String.pad_trailing("support", 8)]
  defp pad(other), do: [:reset, String.pad_trailing(other, 8)]

  defp set(email, role) do
    case Accounts.set_role(email, role) do
      {:ok, user} ->
        Mix.shell().info([:green, "#{user.email} is now ", :reset, role])

        # Said plainly, because revoking your own admin from a machine you
        # are about to log out of is a recoverable mistake only if you know
        # you made it.
        if role == "owner" and Accounts.privileged_users() == [] do
          Mix.shell().info([
            :yellow,
            "\nNobody holds a role now. Nothing on the Data & sync page can be changed\n",
            "until somebody does.\n"
          ])
        end

      {:error, :not_found} ->
        Mix.raise("no account with the address #{email}")

      {:error, changeset} ->
        Mix.raise("could not set the role: #{inspect(changeset.errors)}")
    end
  end
end
