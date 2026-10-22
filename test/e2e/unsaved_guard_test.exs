defmodule PairingsEngineWeb.E2E.UnsavedGuardTest do
  @moduledoc """
  A Settings page with edits nobody saved asks before a link takes them
  away, in the app's own confirm dialog. Lives in the browser because the
  bookkeeping does (`.UnsavedGuard` in `PairingsEngineWeb.SettingsSupport`):
  no LiveViewTest ever sees it.
  """
  use PairingsEngineWeb.E2ECase

  alias PairingsEngine.Tournaments
  alias PairingsEngine.Accounts.Scope

  setup %{conn: conn} do
    {conn, user} = sign_in(conn)

    {:ok, t} =
      Tournaments.create_tournament(Scope.for_user(user), %{
        "name" => "Guarded Open",
        "type" => "swiss",
        "rounds_count" => "5"
      })

    {:ok, conn: conn, t: t}
  end

  defp dates_link(t), do: ~s(#settings-nav a[href="/t/#{t.id}/settings/dates"])

  test "an unsaved edit asks; Cancel stays, OK leaves", %{conn: conn, t: t} do
    conn
    |> visit("/t/#{t.id}/settings")
    |> assert_has("body .phx-connected")
    |> fill_in("Venue", with: "Town hall")
    |> click(dates_link(t))
    |> assert_has("dialog.pe-confirm", text: "not saved")
    |> within("dialog.pe-confirm", &click_button(&1, "Cancel"))
    |> refute_has("dialog.pe-confirm")
    |> assert_has("#tournament-settings-form")
    |> click(dates_link(t))
    |> within("dialog.pe-confirm", &click_button(&1, "OK"))
    |> assert_has("#round-dates-form")
  end

  test "nothing typed, nothing asked", %{conn: conn, t: t} do
    conn
    |> visit("/t/#{t.id}/settings")
    |> assert_has("body .phx-connected")
    |> click(dates_link(t))
    |> assert_has("#round-dates-form")
    |> refute_has("dialog.pe-confirm")
  end
end
