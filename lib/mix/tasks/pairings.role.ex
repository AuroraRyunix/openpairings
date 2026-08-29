defmodule Mix.Tasks.Pairings.Role do
  @shortdoc "Grant or revoke an administrator or support role"

  @moduledoc """
  Who may change how this installation is wired up.

      mix pairings.role                        # who currently holds a role
      mix pairings.role someone@example.com admin
      mix pairings.role someone@example.com support
      mix pairings.role someone@example.com owner    # revoke

      mix pairings.role --ensure "a@x.com,b@x.com" admin   # for the deploy

  ## `--ensure`, and what it means for revoking

  The deploy script runs `--ensure` with `ADMIN_EMAILS` after migrating, so
  the addresses a deployment declares also hold the role in the database.
  Two independent routes to the same authority from one setting: the app can
  be administered even if `ADMIN_EMAILS` never reaches it, and the role
  survives someone later editing it out of the unit.

  It differs from a hand-run grant in one way, deliberately: **an address
  with no account is not an error.** On a fresh box, or before somebody's
  first SSO sign-in, there is no row to promote, and aborting a deploy over
  that would be absurd - the account will exist the moment its owner logs
  in, and the declared route covers them meanwhile. A wrong *role* is still
  an error, because that is a typo in the deployment's configuration.

  The consequence to know: **it re-grants on every deploy.** So
  `DEPLOY_ADMIN_EMAILS` is the source of truth for who administers, and
  demoting somebody still listed there lasts until the next deploy. To
  revoke for good, take the address out of the deploy configuration *and*
  run `mix pairings.role <email> owner`. Doing only the second is the
  mistake this paragraph exists to prevent.

  It reconciles only the addresses it is given: an account not named is left
  exactly as it is. So removing an address stops it being re-granted, and
  does not take away a role somebody already holds - which is why revoking
  needs both halves.

  Within an address it sets what is named, in either direction. The deploy
  only ever passes `admin`, but naming a lesser role lowers one.

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
      ["--ensure", emails, role] when role in ~w(owner support admin) -> ensure(emails, role)
      ["--ensure", _emails, role] -> Mix.raise(unknown_role(role))
      [email, role] when role in ~w(owner support admin) -> set(email, role)
      [_email, role] -> Mix.raise(unknown_role(role))
      _ -> Mix.raise("usage: mix pairings.role [--ensure] [EMAIL[,EMAIL...] #{roles()}]")
    end
  end

  defp unknown_role(role), do: "unknown role #{inspect(role)}: expected one of #{roles()}"

  defp roles, do: Enum.join(User.roles(), " | ")

  defp start_repo do
    {:ok, _} = Application.ensure_all_started(:ecto_sql)

    # Tolerating "already started" is not test scaffolding: the task is also
    # reachable from a shell where the application is up, and refusing to run
    # there would be a puzzle rather than a safeguard.
    case PairingsEngine.Repo.start_link(pool_size: 1) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> Mix.raise("could not reach the database: #{inspect(reason)}")
    end
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

  # `--ensure` is the deploy's mode, and differs from a hand-run grant in the
  # one way that matters: **an address with no account is not an error.**
  #
  # On a fresh box, or before somebody's first SSO sign-in, there is no row to
  # promote. Treating that as a failure would abort a deploy over an account
  # that is going to exist the first time its owner logs in, and which
  # `ADMIN_EMAILS` covers in the meantime without any row at all.
  #
  # A wrong role name IS still an error, because that is a typo in the
  # deployment's configuration and silently doing nothing about it is how an
  # installation ends up with nobody able to administer it.
  defp ensure(emails, role) do
    addresses =
      emails
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if addresses == [] do
      Mix.shell().info("No addresses given; nothing to ensure.")
    else
      Enum.each(addresses, &ensure_one(&1, role))
    end
  end

  defp ensure_one(email, role) do
    case Accounts.get_user_by_email(email) do
      nil ->
        Mix.shell().info([
          :yellow,
          "· #{email} has no account yet - not granted.\n",
          :reset,
          "  It will need this run again after they first sign in. If the address\n",
          "  is in ADMIN_EMAILS they can administer regardless, with no row.\n"
        ])

      user ->
        if User.role(user) == String.to_existing_atom(role) do
          Mix.shell().info([:green, "· #{email} is already #{role}", :reset])
        else
          case Accounts.set_role(email, role) do
            {:ok, _} ->
              Mix.shell().info([:green, "· #{email} is now #{role}", :reset])

            {:error, changeset} ->
              Mix.raise("could not set the role for #{email}: #{inspect(changeset.errors)}")
          end
        end
    end
  end

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
