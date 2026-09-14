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

  describe "\"Check for updates now\"" do
    setup do
      previous = Application.get_env(:pairings_engine, :local_mode)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:pairings_engine, :local_mode)
          value -> Application.put_env(:pairings_engine, :local_mode, value)
        end

        :ets.delete_all_objects(:update_notice)
      end)

      :ets.delete_all_objects(:update_notice)
      :ok
    end

    defp stub(fun), do: Req.Test.stub(PairingsEngine.UpdatesTest, fun)

    defp release(tag) do
      %{
        "tag_name" => tag,
        "html_url" => "https://github.com/AuroraRyunix/openpairings/releases/tag/#{tag}",
        "draft" => false,
        "prerelease" => false
      }
    end

    test "does not exist at all on a hosted server", %{conn: conn} do
      Application.put_env(:pairings_engine, :local_mode, false)

      {:ok, _lv, html} = live(conn, ~p"/admin")

      refute html =~ "Check for updates now"
    end

    test "a hosted server's event handler is a no-op even if sent directly", %{conn: conn} do
      Application.put_env(:pairings_engine, :local_mode, false)
      stub(fn _conn -> raise "must not contact GitHub on a hosted server" end)

      {:ok, lv, _html} = live(conn, ~p"/admin")

      html = render_click(lv, "check_updates_now", %{})

      refute html =~ "latest version"
    end

    test "says up to date when GitHub has nothing newer", %{conn: conn} do
      Application.put_env(:pairings_engine, :local_mode, true)
      stub(fn conn -> Req.Test.json(conn, [release("v0.0.1")]) end)

      {:ok, lv, _html} = live(conn, ~p"/admin")

      html = lv |> element("[phx-click='check_updates_now']") |> render_click()

      assert html =~ "latest version"
    end

    test "names the newer version when one exists", %{conn: conn} do
      Application.put_env(:pairings_engine, :local_mode, true)
      stub(fn conn -> Req.Test.json(conn, [release("v99.0.0")]) end)

      {:ok, lv, _html} = live(conn, ~p"/admin")

      html = lv |> element("[phx-click='check_updates_now']") |> render_click()

      assert html =~ "99.0.0"

      # The banner above picks it up from the same write, via the PubSub
      # broadcast `Checker.put/1` makes on a changed answer - see
      # `PairingsEngine.Updates.Checker.check_now_manual/0` and
      # `PairingsEngineWeb.UpdateNotice`. That broadcast is a separate
      # message the LiveView processes after this click's own reply, so it
      # is asserted on a follow-up render rather than the click's return.
      assert render(lv) =~ "Update available"
    end

    test "says it could not reach GitHub on a transport failure", %{conn: conn} do
      Application.put_env(:pairings_engine, :local_mode, true)
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      {:ok, lv, _html} = live(conn, ~p"/admin")

      html = lv |> element("[phx-click='check_updates_now']") |> render_click()

      assert html =~ "Couldn&#39;t reach GitHub." or html =~ "Couldn't reach GitHub."
    end

    test "a second click shortly after is rate-limited", %{conn: conn} do
      Application.put_env(:pairings_engine, :local_mode, true)
      stub(fn conn -> Req.Test.json(conn, [release("v0.0.1")]) end)

      {:ok, lv, _html} = live(conn, ~p"/admin")

      lv |> element("[phx-click='check_updates_now']") |> render_click()
      html = lv |> element("[phx-click='check_updates_now']") |> render_click()

      assert html =~ "too recently"
    end
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

      assert html =~ "Changed the role of #{colleague.email} from Account owner to Administrator."
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
