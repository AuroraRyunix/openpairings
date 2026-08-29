defmodule PairingsEngineWeb.AdminAccessTest do
  @moduledoc """
  Who can reach the machine-wide pages at all.

  Gating the buttons on Connections was half the job and shipped that way:
  an ordinary account could still open the page and read the publishing
  address, the backup filenames and their sizes, and when each rating list
  last synced. None of it is a password; all of it is the operator's
  business rather than every arbiter's.

  So both halves are pinned here - the nav link is not offered, AND the
  route refuses. A link is a courtesy; a bookmark or a typed URL is not,
  and the markup gate alone would leave the page serving to anyone who
  guessed it.
  """
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.Accounts

  setup :register_and_log_in_user

  defp as(conn, role) do
    user = PairingsEngine.AccountsFixtures.user_fixture()
    {:ok, user} = Accounts.set_role(user.email, role)
    {log_in_user(conn, user), user}
  end

  describe "an ordinary account" do
    test "is not offered either page in the top bar", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/")

      refute html =~ ~s|href="/fide"|
      refute html =~ ~s|href="/admin"|
    end

    test "is refused Connections, not merely shown it read-only", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/", flash: %{"error" => message}}}} =
               live(conn, ~p"/fide")

      assert message =~ "administrators"
    end

    test "is refused Admin", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin")
    end
  end

  describe "support" do
    test "may open Connections and is offered the link", %{conn: conn} do
      {conn, _user} = as(conn, "support")

      {:ok, _lv, html} = live(conn, ~p"/fide")
      assert html =~ "Connections"

      {:ok, _lv, home} = live(conn, ~p"/")
      assert home =~ ~s|href="/fide"|
    end

    test "but not Admin, and is not offered it", %{conn: conn} do
      # The whole point of the middle role: it can look at the diagnostics
      # without being able to hand itself the authority to change them.
      {conn, _user} = as(conn, "support")

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin")

      {:ok, _lv, home} = live(conn, ~p"/")
      refute home =~ ~s|href="/admin"|
    end
  end

  describe "an administrator" do
    test "is offered both, and can open both", %{conn: conn} do
      {conn, _user} = as(conn, "admin")

      {:ok, _lv, home} = live(conn, ~p"/")
      assert home =~ ~s|href="/fide"|
      assert home =~ ~s|href="/admin"|

      assert {:ok, _lv, _html} = live(conn, ~p"/fide")
      assert {:ok, _lv, _html} = live(conn, ~p"/admin")
    end
  end

  describe "a local installation" do
    setup do
      previous = Application.get_env(:pairings_engine, :local_mode)
      Application.put_env(:pairings_engine, :local_mode, true)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:pairings_engine, :local_mode)
          value -> Application.put_env(:pairings_engine, :local_mode, value)
        end
      end)

      :ok
    end

    test "has no roles and is refused nothing", %{conn: conn} do
      # An arbiter's laptop has no accounts to hold a role. Hiding the page
      # there would remove a feature rather than protect anything - the
      # listener is on loopback and the person at the keyboard owns the
      # machine.
      {:ok, _lv, home} = live(conn, ~p"/")
      assert home =~ ~s|href="/fide"|
      assert home =~ ~s|href="/admin"|

      assert {:ok, _lv, _html} = live(conn, ~p"/admin")
    end
  end
end
