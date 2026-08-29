defmodule Mix.Tasks.PairingsRoleTest do
  @moduledoc """
  The `--ensure` mode, because a deploy runs it unattended.

  The hand-run modes are covered by `PairingsEngine.AuthzTest` through
  `Accounts.set_role/2`, which is where their substance lives. What is
  tested here is the one thing `--ensure` does differently, and the reason
  it exists at all:

  **An address with no account is not an error.** The deploy script calls
  this after migrating and before restarting. On a first deploy - or before
  somebody's first SSO sign-in - there is no row to promote, and treating
  that as a failure would abort a deploy over an account that will exist the
  moment its owner logs in, and which `ADMIN_EMAILS` covers meanwhile with
  no row at all.

  A wrong *role* still fails, because that is a typo in the deployment's own
  configuration, and an installation quietly ending up with nobody able to
  administer it is the failure this whole feature exists to prevent.
  """
  use PairingsEngine.DataCase, async: false

  import ExUnit.CaptureIO
  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.Accounts
  alias PairingsEngine.Accounts.User

  defp run(argv) do
    capture_io(fn -> Mix.Tasks.Pairings.Role.run(argv) end)
  end

  defp role_of(email), do: email |> Accounts.get_user_by_email() |> User.role()

  describe "--ensure" do
    test "grants the role to an account that does not hold it" do
      user = user_fixture()

      out = run(["--ensure", user.email, "admin"])

      assert role_of(user.email) == :admin
      assert out =~ "is now admin"
    end

    test "an address with no account is reported, not raised" do
      # The property the deploy depends on. If this ever raises, a first
      # deploy to a fresh box fails at the last step before the restart.
      out = run(["--ensure", "nobody@example.com", "admin"])

      assert out =~ "no account yet"
      assert out =~ "ADMIN_EMAILS"
    end

    test "one missing address does not stop the others being granted" do
      user = user_fixture()

      run(["--ensure", "ghost@example.com,#{user.email}", "admin"])

      assert role_of(user.email) == :admin
    end

    test "is idempotent, and says so rather than writing again" do
      user = user_fixture()
      run(["--ensure", user.email, "admin"])

      out = run(["--ensure", user.email, "admin"])

      assert out =~ "already admin"
      assert role_of(user.email) == :admin
    end

    test "whitespace around addresses is tolerated" do
      # The value arrives from a deploy .env, where somebody will eventually
      # write "a@x.com, b@x.com" with a space after the comma.
      user = user_fixture()

      run(["--ensure", "  #{user.email} , ", "admin"])

      assert role_of(user.email) == :admin
    end

    test "an unknown role fails, even in the deploy's own mode" do
      user = user_fixture()

      assert_raise Mix.Error, ~r/unknown role/, fn ->
        run(["--ensure", user.email, "root"])
      end

      assert role_of(user.email) == :owner
    end

    test "an empty list is a no-op rather than an error" do
      # `DEPLOY_ADMIN_EMAILS=` set but blank. The deploy guards on this too,
      # so this is the second of two answers to the same mistake.
      out = run(["--ensure", "   ", "admin"])

      assert out =~ "nothing to ensure"
    end

    test "it sets the declared role, in either direction" do
      # Not "grants and never demotes" - it reconciles to what is named, so
      # naming a lesser role lowers one. The deploy only ever passes `admin`,
      # but the mode is not admin-only and should not be described as if it
      # were.
      user = user_fixture()
      {:ok, _} = Accounts.set_role(user.email, "admin")

      run(["--ensure", user.email, "support"])

      assert role_of(user.email) == :support
    end

    test "an address it is not given is left alone" do
      # This is the true half of "it never takes anything away", and the one
      # that matters for the deploy: removing somebody from
      # DEPLOY_ADMIN_EMAILS stops them being re-granted, it does not revoke
      # what they hold. Revoking for good is the deploy config AND
      # `mix pairings.role <email> owner`.
      keep = user_fixture()
      {:ok, _} = Accounts.set_role(keep.email, "admin")
      other = user_fixture()

      run(["--ensure", other.email, "admin"])

      assert role_of(keep.email) == :admin
    end
  end
end
