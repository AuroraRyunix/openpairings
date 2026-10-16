defmodule PairingsEngineWeb.UserLive.SettingsLiveBoardsTest do
  @moduledoc "The account page's Live boards section: the boxes connected to the account."
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.BoardLink

  setup :register_and_log_in_user

  test "says when no box is connected", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/users/settings")

    assert has_element?(view, "#live-boards")
    assert has_element?(view, "#board-box-none")
    assert has_element?(view, ~s(a[href="#live-boards"]))
  end

  test "lists the account's boxes, and Withdraw cuts one off", %{conn: conn, scope: scope} do
    {:ok, link, grant} = BoardLink.connect(scope, label: "Alnasl - Hall A")
    {:ok, secret} = BoardLink.redeem_grant(grant)
    other = PairingsEngine.AccountsFixtures.user_scope_fixture()
    {:ok, theirs, _grant} = BoardLink.connect(other, label: "Not mine")

    {:ok, view, _html} = live(conn, ~p"/users/settings")

    assert view |> element("#board-box-#{link.id}") |> render() =~ "Alnasl - Hall A"
    assert view |> element("#board-box-meta-#{link.id}") |> render() =~ link.secret_hint
    assert view |> element("#board-box-meta-#{link.id}") |> render() =~ "Never used"
    refute has_element?(view, "#board-box-#{theirs.id}")

    view |> element("#board-box-revoke-#{link.id}") |> render_click()

    refute has_element?(view, "#board-box-#{link.id}")
    assert has_element?(view, "#board-box-none")
    assert :error = BoardLink.authenticate(secret)
  end

  test "another account's box cannot be withdrawn from here", %{conn: conn} do
    other = PairingsEngine.AccountsFixtures.user_scope_fixture()
    {:ok, theirs, _grant} = BoardLink.connect(other, label: "Not mine")

    {:ok, view, _html} = live(conn, ~p"/users/settings")
    render_click(view, "revoke_board_box", %{"id" => to_string(theirs.id)})

    assert [_] = BoardLink.list_account_links(other)
  end
end
