defmodule PairingsEngineWeb.TopbarMenusTouchTest do
  # The Advanced and Settings menus must work by tap and keyboard, not by
  # hover: they are native <details>/<summary> toggles with ids, share one
  # exclusive group, and nothing about opening them depends on :hover.
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.Tournaments

  setup :register_and_log_in_user

  setup %{scope: scope} do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "Menus",
        "type" => "swiss",
        "rounds_count" => "5"
      })

    %{tournament: tournament}
  end

  test "Advanced and Settings render as tap-toggled disclosure controls", %{
    conn: conn,
    tournament: t
  } do
    {:ok, view, html} = live(conn, ~p"/t/#{t.id}/players")

    for id <- ["topbar-advanced-toggle", "topbar-settings-toggle"] do
      assert has_element?(view, "details.topbar-menu[name=topbar-popover] > summary##{id}")
      assert has_element?(view, "summary##{id}[aria-haspopup=true]")
    end

    # Opening is the browser's own tap/Enter/Space on <summary>: no hover
    # utility classes and no mouse-only handlers on the controls.
    refute html =~ ~r/<summary[^>]*(group-hover|phx-hover|onmouseenter|mouseenter)/
    refute html =~ ~r/<details[^>]*(group-hover|onmouseenter|mouseenter)/

    # Each menu keeps its items inside the details, so a tap opens them.
    assert has_element?(view, "details.topbar-menu .topbar-menu-panel a.topbar-menu-item")
  end

  test "the phone layout anchors menu panels to the bar, not position: fixed in the scroller" do
    css = File.read!("assets/css/app.css")
    [_, phone] = String.split(css, "@media (max-width: 768px) {", parts: 2)
    [phone | _] = String.split(phone, "@media (max-width: 480px)", parts: 2)

    assert phone =~ ".topbar { position: relative; }"
    assert phone =~ ~r/\.topbar-menu\[open\] > \.topbar-menu-panel \{[^}]*position: absolute/
    refute phone =~ ~r/\.topbar-menu\[open\] > \.topbar-menu-panel \{[^}]*position: fixed/
  end
end
