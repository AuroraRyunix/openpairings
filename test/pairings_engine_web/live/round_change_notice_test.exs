defmodule PairingsEngineWeb.RoundChangeNoticeTest do
  @moduledoc """
  A round paired, unpaired or published by somebody else says so on the open
  Pairings and Players pages - and the session that did it hears nothing.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import PairingsEngine.NextRoundPreviewFixture

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Round, Tournament}
  alias PairingsEngineWeb.RoundChangeNotice

  setup :register_and_log_in_user

  setup %{user: user} do
    t =
      Repo.insert!(%Tournament{
        name: "Notice",
        type: "swiss",
        rounds_count: 3,
        round_dates: ~w(2026-09-01 2026-09-02 2026-09-03),
        tiebreaks: ~w(BH),
        user_id: user.id
      })

    for i <- 1..8, do: insert_player(t, i)
    %{t: t}
  end

  describe "notice/2" do
    test "names what changed, and nothing when nothing did" do
      a = [{1, 10, nil}]
      assert RoundChangeNotice.notice(a, a) == nil
      assert RoundChangeNotice.notice(a, a ++ [{2, 5, nil}]) =~ "Round 2 was just paired"
      assert RoundChangeNotice.notice(a ++ [{2, 5, nil}], a) =~ "Round 2 was just unpaired"
      assert RoundChangeNotice.notice(a, [{1, 11, nil}]) =~ "Round 1 was just paired again"
      assert RoundChangeNotice.notice(a, [{1, 10, ~U[2026-09-01 10:00:00Z]}]) =~ "published"
      assert RoundChangeNotice.notice([{1, 10, ~U[2026-09-01 10:00:00Z]}], a) =~ "withdrawn"
    end
  end

  test "pairing in another session notifies the open page", %{conn: conn, t: t} do
    {:ok, view, _html} = live(conn, ~p"/t/#{t.id}/pairings")
    refute render(view) =~ "was just paired elsewhere"

    # Somebody else: the engine, not this page's own click.
    pair!(t)
    _ = :sys.get_state(view.pid)

    assert render(view) =~ "Round 1 was just paired elsewhere."
  end

  test "the session that paired hears nothing", %{conn: conn, t: t} do
    {:ok, view, _html} = live(conn, ~p"/t/#{t.id}/pairings")
    render_click(view, "pair", %{})
    _ = :sys.get_state(view.pid)

    refute render(view) =~ "elsewhere"
  end

  test "a result entered elsewhere is not a round change", %{conn: conn, t: t} do
    pair!(t)
    {:ok, view, _html} = live(conn, ~p"/t/#{t.id}/pairings")

    Tournaments.broadcast_tournament_change(t.id, :rounds)
    _ = :sys.get_state(view.pid)

    refute render(view) =~ "elsewhere"
  end

  test "unpairing and publishing elsewhere are noticed", %{conn: conn, t: t} do
    pair!(t)
    {:ok, view, _html} = live(conn, ~p"/t/#{t.id}/pairings")

    Repo.update_all(from(r in Round, where: r.tournament_id == ^t.id and r.number == 1),
      set: [published_at: ~U[2026-09-01 10:00:00Z]]
    )

    Tournaments.broadcast_tournament_change(t.id, :rounds)
    _ = :sys.get_state(view.pid)
    assert render(view) =~ "Round 1 was just published elsewhere."
  end

  test "the Players page is told too", %{conn: conn, t: t} do
    {:ok, view, _html} = live(conn, ~p"/t/#{t.id}/players")
    pair!(t)
    _ = :sys.get_state(view.pid)

    assert render(view) =~ "Round 1 was just paired elsewhere."
  end
end
