defmodule PairingsEngineWeb.LocalModeSurfacesTest do
  @moduledoc """
  A local install has one owner and signs them in on sight, so the parts of
  the app that assume a multi-user server have nothing to do there.

  0.17.1 shipped local mode properly - auto-signed-in owner, loopback-pinned,
  log-out link hidden with a stated reason - and then nothing else was told.
  `grep -rn "local_mode" lib/pairings_engine_web/live/` returned only
  `admin_live.ex`. These are the four surfaces that were still offering a
  multi-user server's controls, and the rule they now follow is the one the
  log-out link was removed under: **a control that visibly does nothing is
  worse than no control.**
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.Tournaments

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:pairings_engine, :local_mode)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:pairings_engine, :local_mode)
        value -> Application.put_env(:pairings_engine, :local_mode, value)
      end
    end)

    :ok
  end

  defp local_mode(on?), do: Application.put_env(:pairings_engine, :local_mode, on?)

  defp a_tournament(scope) do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "Local", "rounds_count" => 3})

    tournament
  end

  describe "the Settings link in the top bar" do
    test "is offered on a hosted install", %{conn: conn} do
      local_mode(false)
      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ ~s|href="/users/settings"|
    end

    test "is not offered on a local install", %{conn: conn} do
      # The page it links to offers change-email and change-password for an
      # account nobody logs into, and mails its confirmation to a terminal.
      local_mode(true)
      {:ok, _lv, html} = live(conn, ~p"/")

      refute html =~ ~s|href="/users/settings"|
    end
  end

  describe "the Share / Team card" do
    test "is offered on a hosted install", %{conn: conn, scope: scope} do
      local_mode(false)
      tournament = a_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")

      assert html =~ "Share / Team"
      assert html =~ "add-collaborator-form"
    end

    test "is not offered on a local install", %{conn: conn, scope: scope} do
      # The invitation is an email, which goes to the console there, and the
      # listener is loopback-pinned so nobody else could open the link.
      local_mode(true)
      tournament = a_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")

      refute html =~ "add-collaborator-form"
    end
  end

  describe "the sign-in and sign-up pages" do
    for {path, what} <- [
          {"/users/register", "registration"},
          {"/users/log-in", "log-in"}
        ] do
      test "#{what} answers on a hosted install", %{conn: conn} do
        local_mode(false)
        assert {:ok, _lv, _html} = live(build_conn(), unquote(path))
        _ = conn
      end

      test "#{what} sends a local install home instead", %{conn: conn} do
        # Not a 404: the page exists on a hosted install and the visitor has
        # done nothing wrong. The links are already hidden; this is the
        # bookmark and the typed URL.
        local_mode(true)
        assert {:error, {:redirect, %{to: "/"}}} = live(build_conn(), unquote(path))
        _ = conn
      end
    end
  end

  describe "what is deliberately left alone" do
    test "log out still routes on a local install", %{conn: conn} do
      # It is already inert there - the next request signs the same owner
      # straight back in - and an escape hatch that does nothing beats one
      # that refuses.
      local_mode(true)

      assert conn |> delete(~p"/users/log-out") |> redirected_to() == ~p"/"
    end
  end
end
