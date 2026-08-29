defmodule PairingsEngine.AuthzTest do
  @moduledoc """
  The one predicate every infrastructure gate reads.

  Two things are pinned here, and they pull in opposite directions - which
  is why they are worth stating together rather than trusting each caller to
  get right:

    * on a hosted installation, **authenticating is not authorisation**. An
      ordinary account cannot administer, and neither can an 02cloud SSO
      account. That second one is the whole point of the role: SSO used to
      be the gate, which made every account in a federated directory an
      administrator of the publishing configuration.

    * on a local installation, **there is nothing to authorise**. No role is
      needed, or possible - a local run auto-signs-in a synthetic owner and
      pins its listener to loopback, so the person at the keyboard is the
      only person who can reach the page, and they already hold the database
      file and the binary.

  Getting the second one wrong is not a security bug, it is a broken
  product: it locked arbiters out of setting where their own laptop
  publishes, syncing the rating list and taking a backup, with no way to
  grant themselves anything.
  """
  use PairingsEngine.DataCase, async: false

  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.Accounts
  alias PairingsEngine.Accounts.User
  alias PairingsEngine.Authz

  setup do
    previous = Application.get_env(:pairings_engine, :local_mode)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:pairings_engine, :local_mode)
        value -> Application.put_env(:pairings_engine, :local_mode, value)
      end
    end)

    # Explicitly off. Inheriting it would make every hosted assertion below
    # depend on config set somewhere else.
    Application.put_env(:pairings_engine, :local_mode, false)
    :ok
  end

  defp with_role(role) do
    user = user_fixture()
    {:ok, user} = Accounts.set_role(user.email, role)
    user
  end

  defp sso_user do
    {:ok, user} =
      Accounts.find_or_create_from_keycloak(%{
        sub: "sub-#{System.unique_integer()}",
        email: "sso-#{System.unique_integer()}@example.com"
      })

    user
  end

  describe "a hosted installation" do
    test "an ordinary account administers nothing" do
      user = user_fixture()

      refute Authz.may_administer?(user)
      refute Authz.may_support?(user)
    end

    test "an SSO account is not an administrator" do
      user = sso_user()

      # The change of 2026-08-29. `User.sso?/1` still answers true here -
      # this account really did come through 02cloud - and that is now
      # simply a different question from what it may do.
      assert User.sso?(user)
      refute Authz.may_administer?(user)
      refute Authz.may_support?(user)
    end

    test "an administrator administers, and may also look" do
      admin = with_role("admin")

      assert Authz.may_administer?(admin)
      assert Authz.may_support?(admin)
    end

    test "support may look and nothing else" do
      support = with_role("support")

      assert Authz.may_support?(support)
      refute Authz.may_administer?(support)
    end

    test "nobody signed in at all administers nothing" do
      refute Authz.may_administer?(nil)
      refute Authz.may_support?(nil)
    end
  end

  describe "a local installation" do
    setup do
      Application.put_env(:pairings_engine, :local_mode, true)
      :ok
    end

    test "the local owner may do everything, holding no role" do
      owner = Accounts.local_owner!()

      # It holds no role and never will: nothing creates one, and the whole
      # point is that it does not need one.
      assert User.role(owner) == :owner
      refute User.sso?(owner)

      assert Authz.may_administer?(owner)
      assert Authz.may_support?(owner)
    end

    test "so may anyone else, because there is nobody else" do
      assert Authz.may_administer?(user_fixture())
      assert Authz.may_administer?(nil)
    end
  end

  describe "an address the deployment declares" do
    setup do
      previous = Application.get_env(:pairings_engine, :admin_emails)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:pairings_engine, :admin_emails)
          value -> Application.put_env(:pairings_engine, :admin_emails, value)
        end
      end)

      :ok
    end

    defp declare(emails), do: Application.put_env(:pairings_engine, :admin_emails, emails)

    test "administers, holding no role" do
      # Closes the bootstrap gap: a freshly migrated hosted installation has
      # nobody in the database, so without this the first act after every
      # deploy is a mix task somebody has to remember.
      user = user_fixture()
      declare([String.downcase(user.email)])

      assert User.role(user) == :owner
      assert Authz.may_administer?(user)
    end

    test "and may look, which the role alone would not have given them" do
      # `User.support?/1` reads the ROLE, and a declared administrator has
      # none - so support had to be derived from may_administer?/1 rather
      # than from the column, or the person with the most authority on the
      # installation would have been refused the read-only diagnostics.
      user = user_fixture()
      declare([String.downcase(user.email)])

      assert Authz.may_support?(user)
    end

    test "matched without regard to case" do
      user = user_fixture()
      declare([String.upcase(user.email)])

      assert Authz.may_administer?(user)
    end

    test "and nobody else" do
      declare(["someone-else@example.com"])

      refute Authz.may_administer?(user_fixture())
    end

    test "an empty or unset list declares nobody" do
      for value <- [[], nil] do
        if value,
          do: declare(value),
          else: Application.delete_env(:pairings_engine, :admin_emails)

        refute Authz.may_administer?(user_fixture())
      end
    end

    test "declaring writes nothing, so a demotion is not undone by a restart" do
      # The reason this declares rather than promotes. A boot-time UPDATE
      # would silently re-grant admin to anyone still listed, every restart,
      # including someone deliberately demoted an hour earlier.
      user = user_fixture()
      declare([String.downcase(user.email)])
      assert Authz.may_administer?(user)

      assert Accounts.privileged_users() == []
      assert PairingsEngine.Repo.reload(user).role == "owner"
    end
  end

  describe "the role column" do
    test "defaults to owner" do
      assert User.role(user_fixture()) == :owner
    end

    test "a value this version does not understand is the least privileged" do
      # A hand-edited database, or a role a later version dropped. Raising
      # inside an authorisation check would be worse than either: the check
      # would fail in whatever rescue eventually caught it, and the safe
      # direction to be wrong in is downwards.
      assert User.role(%User{role: "sysadmin"}) == :owner
      assert User.role(%User{role: nil}) == :owner
      refute Authz.may_administer?(%User{role: "sysadmin"})
    end

    test "only the three known roles can be set" do
      user = user_fixture()

      assert {:error, changeset} = Accounts.set_role(user.email, "root")
      assert "must be one of: owner, support, admin" in errors_on(changeset).role
    end

    test "setting one on an address nobody holds says so rather than raising" do
      assert {:error, :not_found} = Accounts.set_role("nobody@example.com", "admin")
    end

    test "a role can be taken away again" do
      admin = with_role("admin")
      assert Authz.may_administer?(admin)

      {:ok, demoted} = Accounts.set_role(admin.email, "owner")
      refute Authz.may_administer?(demoted)
    end

    test "privileged_users lists everyone holding one, and only them" do
      _plain = user_fixture()
      admin = with_role("admin")
      support = with_role("support")

      emails = Enum.map(Accounts.privileged_users(), & &1.email)

      assert admin.email in emails
      assert support.email in emails
      assert length(emails) == 2
    end
  end
end
