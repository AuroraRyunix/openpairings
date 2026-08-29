defmodule PairingsEngineWeb.AdminLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest
  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Accounts, Audit}
  alias PairingsEngine.Accounts.User

  setup :register_and_log_in_user

  # /admin is gated on the admin role (see PairingsEngineWeb.RequireRole),
  # same as Connections - the signed-in user here is an administrator, and
  # any test that cares about a lesser role builds its own.
  setup %{conn: conn, user: user} do
    {:ok, admin} = Accounts.set_role(user.email, "admin")
    {:ok, conn: log_in_user(conn, admin), user: admin}
  end

  test "renders the roles table and this installation's facts", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/admin")

    assert html =~ "Admin</h1>"
    assert html =~ "Who may administer this installation"
    assert html =~ "This installation"
  end

  test "with nothing recorded yet, Recent activity shows the empty state", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/admin")

    assert html =~ "Recent activity"
    assert html =~ "No installation-wide activity recorded yet."
  end

  describe "changing a role" do
    test "updates the role and writes a durable, non-tournament audit row", %{
      conn: conn,
      user: admin
    } do
      colleague = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/admin")

      lv
      |> element("button[phx-value-id='#{colleague.id}'][phx-value-role='support']")
      |> render_click()

      lv |> element("button", "Change the role") |> render_click()

      assert Accounts.get_user!(colleague.id) |> User.role() == :support

      assert [row] = Audit.list_machine_wide()
      assert row.action == "admin.role_changed"
      assert row.tournament_id == nil
      assert row.user_id == admin.id
      assert row.details["email"] == colleague.email
      assert row.details["changed_fields"]["role"] == ["owner", "support"]
    end

    test "the change appears immediately in the page's own Recent activity list", %{conn: conn} do
      colleague = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/admin")

      lv
      |> element("button[phx-value-id='#{colleague.id}'][phx-value-role='admin']")
      |> render_click()

      html = lv |> element("button", "Change the role") |> render_click()

      assert html =~ "Changed #{colleague.email}&#39;s role: role owner → admin."
      refute html =~ "No installation-wide activity recorded yet."
    end

    test "the acting administrator is shown as the audit row's actor", %{
      conn: conn,
      user: admin
    } do
      colleague = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/admin")

      lv
      |> element("button[phx-value-id='#{colleague.id}'][phx-value-role='support']")
      |> render_click()

      html = lv |> element("button", "Change the role") |> render_click()

      assert html =~ admin.email
    end
  end
end
