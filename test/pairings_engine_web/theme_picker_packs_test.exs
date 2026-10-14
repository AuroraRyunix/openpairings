defmodule PairingsEngineWeb.ThemePickerPacksTest do
  @moduledoc """
  Theme packs as a person meets them: in the top bar's picker, in the data
  the root layout hands its bootstrap script, and as a theme stored on the
  account - including `jorian`, which was built in until it became a pack.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import PairingsEngine.AccountsFixtures
  import PairingsEngine.ThemePackFixtures
  import Phoenix.LiveViewTest

  alias PairingsEngine.Accounts
  alias PairingsEngine.Repo

  setup :themes_dir

  defp page(conn),
    do: conn |> get(~p"/changelog") |> html_response(200) |> LazyHTML.from_document()

  defp packs_data(doc) do
    doc
    |> LazyHTML.query(~s(meta[name="op-theme-packs"]))
    |> LazyHTML.attribute("content")
    |> hd()
    |> Jason.decode!()
  end

  defp has?(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count() > 0

  test "with no packs the picker is the built-ins and the script gets an empty list", %{
    conn: conn
  } do
    doc = page(log_in_user(conn, user_fixture()))

    assert packs_data(doc) == []
    refute has?(doc, ".theme-picker-item.is-pack")
    refute has?(doc, ~s([data-theme-opt="jorian"]))
    assert has?(doc, ~s([data-theme-opt="tomw"]))
  end

  test "an installed pack is offered after the built-ins, with its swatch", %{
    conn: conn,
    themes_dir: dir
  } do
    install_pack(dir, "toon", meta: %{"name" => "Toon", "dark" => true})
    install_pack(dir, "evil", css: ~s(@import "x";))

    doc = page(log_in_user(conn, user_fixture()))

    assert has?(doc, "#theme-pack-toon[data-phx-theme=toon]")
    assert doc |> LazyHTML.query("#theme-pack-toon .theme-pack-swatch i") |> Enum.count() == 3

    assert [%{"id" => "toon", "dark" => true, "css" => "/themes/toon/theme.css?v=" <> _}] =
             packs_data(doc)

    # Refused, and said so where whoever installed it will look.
    assert has?(doc, "#theme-pack-refused-evil")
    refute has?(doc, "#theme-pack-evil")
  end

  test "a pack that vanishes is no longer offered or known to the script", %{
    conn: conn,
    themes_dir: dir
  } do
    path = install_pack(dir, "toon")
    assert [_] = packs_data(page(log_in_user(conn, user_fixture())))

    File.rm_rf!(path)
    doc = page(log_in_user(build_conn(), user_fixture()))
    assert packs_data(doc) == []
    refute has?(doc, "#theme-pack-toon")
  end

  describe "an account that stored jorian" do
    setup do
      user = user_fixture()
      # Stored while Jorian was built in; written past the changeset, which
      # (rightly) no longer accepts it without the pack.
      user = user |> Ecto.Changeset.change(theme: "jorian") |> Repo.update!()
      %{user: user}
    end

    test "gets the pack when it is installed", %{conn: conn, user: user, themes_dir: dir} do
      install_pack(dir, "jorian", meta: %{"name" => "Jorian"})

      doc = page(log_in_user(conn, user))

      assert doc |> LazyHTML.query("html") |> LazyHTML.attribute("data-account-theme") == [
               "jorian"
             ]

      assert [%{"id" => "jorian"}] = packs_data(doc)
    end

    test "falls back to System when it is not", %{conn: conn, user: user} do
      doc = page(log_in_user(conn, user))

      # No account theme on the page, and "jorian" not among the themes the
      # script knows - so a stale `phx:theme` in the browser lands on System
      # too (the script's `known` check).
      assert doc |> LazyHTML.query("html") |> LazyHTML.attribute("data-account-theme") == []
      assert packs_data(doc) == []
    end
  end

  test "Account settings offers an installed pack by name", %{conn: conn, themes_dir: dir} do
    install_pack(dir, "toon", meta: %{"name" => "Toon"})
    user = user_fixture()

    {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/users/settings")
    assert has_element?(lv, ~s(#theme-choices input[value="toon"]))

    {:ok, user} = Accounts.update_user_preferences(user, %{"theme" => "toon"})
    assert user.theme == "toon"
  end
end
