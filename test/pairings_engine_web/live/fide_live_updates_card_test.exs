defmodule PairingsEngineWeb.FideLiveUpdatesCardTest do
  @moduledoc """
  The "Updates" card on the Connections page: desktop-only, and its one
  control - the on/off setting.

  Kept out of `FideLiveTest` (which runs `async: true`) because this
  requires flipping `PairingsEngine.Authz.local_mode?/0`, a global
  `Application.env` read from every process - the same reason
  `PairingsEngineWeb.LocalModeSurfacesTest` is its own `async: false` file
  rather than a describe block bolted onto whichever page it happened to
  test first.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.Accounts
  alias PairingsEngine.Updates

  setup :register_and_log_in_user

  setup %{conn: conn, user: user} do
    {:ok, admin} = Accounts.set_role(user.email, "admin")
    {:ok, conn: log_in_user(conn, admin), user: admin}
  end

  setup do
    previous = Application.get_env(:pairings_engine, :local_mode)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:pairings_engine, :local_mode)
        value -> Application.put_env(:pairings_engine, :local_mode, value)
      end

      Updates.put_enabled(true)
    end)

    :ok
  end

  defp local_mode(on?), do: Application.put_env(:pairings_engine, :local_mode, on?)

  describe "on a hosted server" do
    test "the card is not offered at all", %{conn: conn} do
      local_mode(false)

      {:ok, _lv, html} = live(conn, ~p"/fide")

      refute html =~ "Updates</h2>"
      refute html =~ "toggle_update_check"
    end
  end

  describe "on a desktop install" do
    setup do
      local_mode(true)
      :ok
    end

    test "the card is offered, on by default", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/fide")

      assert html =~ "Updates</h2>"
      assert Updates.enabled?()
    end

    test "turning it off persists and flips the button's label", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/fide")

      html = render_click(lv, "toggle_update_check", %{})

      refute Updates.enabled?()
      assert html =~ "Turn on"
    end

    test "turning it off, then on again, leaves it on", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/fide")

      render_click(lv, "toggle_update_check", %{})
      html = render_click(lv, "toggle_update_check", %{})

      assert Updates.enabled?()
      assert html =~ "Turn off"
    end
  end
end
