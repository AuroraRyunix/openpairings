defmodule PairingsEngineWeb.UserLive.FeaturesTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest
  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.Accounts
  alias PairingsEngine.Features

  describe "the page" do
    test "renders one card per federation, with every switch off by default", %{conn: conn} do
      {:ok, _lv, html} =
        conn |> log_in_user(user_fixture()) |> live(~p"/users/features")

      assert html =~ "Belgium"

      for feature <- Features.catalogue() do
        assert html =~ feature.label
      end
    end

    test "says plainly that switching a feature off changes no tournament", %{conn: conn} do
      {:ok, _lv, html} =
        conn |> log_in_user(user_fixture()) |> live(~p"/users/features")

      assert html =~ "never changes your tournaments"
      assert html =~ "scores exactly as it did"
    end

    test "explains that the two readers depend on the sync's data", %{conn: conn} do
      {:ok, _lv, html} =
        conn |> log_in_user(user_fixture()) |> live(~p"/users/features")

      assert html =~ "read the member list the rating list sync downloads"
      assert html =~ "whatever was last downloaded"
    end

    test "says no other federations are packaged yet", %{conn: conn} do
      {:ok, _lv, html} =
        conn |> log_in_user(user_fixture()) |> live(~p"/users/features")

      assert html =~ "No other federations are packaged yet"
    end

    test "needs a login", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/users/features")
      assert path == ~p"/users/log-in"
    end

    # The whole reason this is not a section of `UserLive.Settings`.
    test "does NOT require sudo mode", %{conn: conn} do
      assert {:ok, _lv, _html} =
               conn
               |> log_in_user(user_fixture(),
                 token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
               )
               |> live(~p"/users/features")
    end
  end

  describe "saving" do
    test "ticking a switch stores exactly that key", %{conn: conn} do
      user = user_fixture()
      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/users/features")

      lv
      |> form("#features-form", %{"feature" => %{"bel_swar_import" => "true"}})
      |> render_change()

      assert Accounts.get_user!(user.id).features == ["bel_swar_import"]
    end

    test "unticking removes it again", %{conn: conn} do
      user = user_fixture()
      {:ok, user} = Features.set_enabled(user, Features.keys())

      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/users/features")

      lv
      |> form("#features-form", %{
        "feature" =>
          Map.new(Features.keys(), fn
            "bel_swar_export" -> {"bel_swar_export", "true"}
            key -> {key, "false"}
          end)
      })
      |> render_change()

      assert Accounts.get_user!(user.id).features == ["bel_swar_export"]
    end

    test "switching the lookup on does not switch the sync on with it", %{conn: conn} do
      user = user_fixture()
      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/users/features")

      lv
      |> form("#features-form", %{"feature" => %{"bel_player_lookup" => "true"}})
      |> render_change()

      stored = Accounts.get_user!(user.id).features
      assert stored == ["bel_player_lookup"]
      refute "bel_ratings_sync" in stored
    end

    test "a crafted key that is not in the catalogue is ignored", %{conn: conn} do
      user = user_fixture()
      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/users/features")

      render_change(lv, "save", %{
        "feature" => %{"bel_club_sync" => "true", "admin_everything" => "true"}
      })

      assert Accounts.get_user!(user.id).features == ["bel_club_sync"]
    end
  end
end
