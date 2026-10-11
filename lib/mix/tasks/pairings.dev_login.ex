defmodule Mix.Tasks.Pairings.DevLogin do
  @shortdoc "Development only: a one-time login link for an account, no mailbox needed"

  @moduledoc """
  Prints a one-time login link for an account on a development checkout,
  creating the account when it does not exist. For looking at a page as an
  administrator without waiting for a mail that the dev mailbox may or may
  not show.

      mix pairings.dev_login                          # dev-admin@example.test, admin
      mix pairings.dev_login someone@example.test owner
      PORT=4010 mix pairings.dev_login                # the link points at that port

  The link is the ordinary magic link (`Accounts.login_user_by_magic_link/1`
  consumes it): open it, press the button, done. It refuses to run anywhere
  but `MIX_ENV=dev`, because a task that mints a login for any address is
  not something a server should have lying around.
  """
  use Mix.Task

  alias PairingsEngine.{Accounts, Repo}
  alias PairingsEngine.Accounts.UserToken

  @impl true
  def run(args) do
    if Mix.env() != :dev do
      Mix.raise("mix pairings.dev_login only runs in MIX_ENV=dev (this is #{Mix.env()}).")
    end

    {email, role} =
      case args do
        [] -> {"dev-admin@example.test", "admin"}
        [email] -> {email, "admin"}
        [email, role | _] -> {email, role}
      end

    Mix.Task.run("app.start")

    user =
      case Accounts.get_user_by_email(email) do
        nil ->
          {:ok, user} = Accounts.register_user(%{email: email})
          user

        user ->
          user
      end

    case Accounts.set_role(email, role) do
      {:ok, _user} -> :ok
      other -> Mix.raise("Could not set the role #{inspect(role)}: #{inspect(other)}")
    end

    {encoded, token} = UserToken.build_email_token(user, "login")
    Repo.insert!(token)

    port = System.get_env("PORT") || "4000"
    Mix.shell().info("http://localhost:#{port}/users/log-in/#{encoded}")
  end
end
