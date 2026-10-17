defmodule PairingsEngineWeb.EnrollmentRevokedTest do
  @moduledoc """
  Revoking a phone broadcasts `{:mobile_enrollment_revoked, id}` on the
  tournament's topic, which every open arbiter page of that tournament
  follows. The Pairings page had no clause for it and died.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Mobile, Repo}
  alias PairingsEngine.Tournaments.Tournament

  setup :register_and_log_in_user

  setup %{user: user} do
    t =
      Repo.insert!(%Tournament{
        name: "Revoke",
        type: "swiss",
        rounds_count: 3,
        round_dates: ~w(2026-09-01 2026-09-02 2026-09-03),
        tiebreaks: ~w(BH),
        user_id: user.id
      })

    %{t: t}
  end

  test "an open Pairings page survives a revoked phone", %{conn: conn, t: t} do
    {:ok, view, _html} = live(conn, ~p"/t/#{t.id}/pairings")

    {:ok, enrollment} = Mobile.create_enrollment(t.id, [])
    {:ok, _} = Mobile.revoke(enrollment)

    send(view.pid, {:mobile_enrollment_revoked, enrollment.id})

    # A render round trip: it only answers if the process is still there.
    assert render(view) =~ "Revoke"
    assert Process.alive?(view.pid)
  end

  test "the page that lists phones drops the revoked one", %{conn: conn, t: t} do
    {:ok, enrollment} = Mobile.create_enrollment(t.id, label: "Gone Helper")
    {:ok, view, html} = live(conn, ~p"/t/#{t.id}/live")
    assert html =~ "Gone Helper"

    {:ok, _} = Mobile.revoke(enrollment)

    refute render(view) =~ "Gone Helper"
  end
end
