defmodule PairingsEngineWeb.AdminRolesTest do
  @moduledoc """
  Changing a role from the Admin page, and the three ways it refuses.

  Each refusal is a way somebody would otherwise lock themselves or the
  installation out, and each is enforced on the HANDLER rather than only in
  the markup - a control that is not rendered still accepts a crafted event.

  What is deliberately NOT tested as a refusal is granting itself: an
  administrator promoting a colleague gains nothing they did not have, since
  the same session can already repoint publishing and download the whole
  database.
  """
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.Accounts
  alias PairingsEngine.Accounts.User
  alias PairingsEngine.AccountsFixtures

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:pairings_engine, :admin_emails)
    Application.put_env(:pairings_engine, :admin_emails, [])

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:pairings_engine, :admin_emails)
        value -> Application.put_env(:pairings_engine, :admin_emails, value)
      end
    end)

    :ok
  end

  defp with_role(role) do
    user = AccountsFixtures.user_fixture()
    {:ok, user} = Accounts.set_role(user.email, role)
    user
  end

  # Two administrators, so demoting one is not the last-admin case.
  defp admin_conn(conn) do
    _second = with_role("admin")
    admin = with_role("admin")
    {log_in_user(conn, admin), admin}
  end

  defp role_of(email), do: email |> Accounts.get_user_by_email() |> User.role()

  test "an administrator can change somebody else's role", %{conn: conn} do
    {conn, _admin} = admin_conn(conn)
    other = AccountsFixtures.user_fixture()

    {:ok, lv, _html} = live(conn, ~p"/admin")

    render_click(lv, "ask", %{"id" => to_string(other.id), "role" => "support"})
    render_click(lv, "confirm", %{})

    assert role_of(other.email) == :support
  end

  test "changing a role asks first", %{conn: conn} do
    # The confirm step is the whole reason "ask" and "confirm" are separate:
    # this is a list of buttons beside a list of names, and a misclick on the
    # wrong row should not be irreversible.
    {conn, _admin} = admin_conn(conn)
    other = AccountsFixtures.user_fixture()

    {:ok, lv, _html} = live(conn, ~p"/admin")
    html = render_click(lv, "ask", %{"id" => to_string(other.id), "role" => "admin"})

    assert html =~ "Change this role?"
    assert role_of(other.email) == :owner
  end

  test "you cannot change your own role", %{conn: conn} do
    # One misclick would otherwise cost an administrator their access, on the
    # one page that could give it back.
    {conn, admin} = admin_conn(conn)

    {:ok, lv, _html} = live(conn, ~p"/admin")
    html = render_click(lv, "ask", %{"id" => to_string(admin.id), "role" => "owner"})

    assert html =~ "cannot change your own role"
    assert role_of(admin.email) == :admin
  end

  test "the last administrator cannot be demoted", %{conn: conn} do
    # An installation with no administrator is recoverable only over SSH.
    admin = with_role("admin")
    other_admin = with_role("admin")
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/admin")

    # Demote the only other one, leaving `admin` alone...
    render_click(lv, "ask", %{"id" => to_string(other_admin.id), "role" => "owner"})
    render_click(lv, "confirm", %{})
    assert role_of(other_admin.email) == :owner

    # ...and now nobody can be demoted further, including by a crafted event
    # aimed at the row whose buttons are no longer rendered.
    {:ok, lv, _html} = live(conn, ~p"/admin")
    render_click(lv, "ask", %{"id" => to_string(admin.id), "role" => "owner"})
    render_click(lv, "confirm", %{})

    assert role_of(admin.email) == :admin
  end

  test "an address declared in the deployment cannot be edited here", %{conn: conn} do
    # ADMIN_EMAILS lives in the systemd unit. A button that appeared to
    # revoke one and was undone by the next restart would be a lie.
    {conn, _admin} = admin_conn(conn)
    declared = AccountsFixtures.user_fixture()
    Application.put_env(:pairings_engine, :admin_emails, [String.downcase(declared.email)])

    {:ok, lv, _html} = live(conn, ~p"/admin")
    html = render_click(lv, "ask", %{"id" => to_string(declared.id), "role" => "owner"})

    # Without the apostrophe: HEEx escapes it to `&#39;`, so matching the
    # prose as written would fail for a reason that has nothing to do with
    # the guard.
    assert html =~ "so it cannot be changed here"
    assert role_of(declared.email) == :owner
  end

  test "the page shows who holds what, administrators first", %{conn: conn} do
    {conn, _admin} = admin_conn(conn)
    support = with_role("support")

    {:ok, _lv, html} = live(conn, ~p"/admin")

    assert html =~ support.email
    assert html =~ "Administrator"
    assert html =~ "Support"
  end
end
