defmodule PairingsEngineWeb.PairingsLiveEchoTest do
  @moduledoc """
  The Pairings page receives its own "Pair round" broadcast like every
  other open page, after it already reloaded from the data that broadcast
  is about. It skips that second reload - and only that one: anything
  written since its own reload, by anybody, still reloads it.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import PairingsEngine.NextRoundPreviewFixture

  alias PairingsEngine.{PairTiming, Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Pairing, Tournament}

  setup :register_and_log_in_user

  setup %{user: user} do
    test = self()
    id = "pairings-live-echo-#{System.unique_integer()}"

    :telemetry.attach(
      id,
      PairTiming.prefix() ++ [:refresh, :stop],
      fn _, _, _, _ -> send(test, :reloaded) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)

    t =
      Repo.insert!(%Tournament{
        name: "Echo",
        type: "swiss",
        rounds_count: 3,
        round_dates: ~w(2026-09-01 2026-09-02 2026-09-03),
        tiebreaks: ~w(BH),
        user_id: user.id
      })

    for i <- 1..8, do: insert_player(t, i)
    %{t: t}
  end

  defp reloads(count \\ 0) do
    receive do
      :reloaded -> reloads(count + 1)
    after
      0 -> count
    end
  end

  # Round 2, as most clicks are: round 1 also draws the initial colour and
  # numbers the players, and each of those says so in a broadcast of its
  # own, which the page reloads for.
  defp paired(conn, t) do
    pair!(t)
    finish_latest_round(t)

    {:ok, view, _html} = live(conn, ~p"/t/#{t.id}/pairings")
    _ = reloads()
    render_click(view, "pair", %{})
    # Its own broadcast is handled by the time this returns.
    _ = :sys.get_state(view.pid)
    view
  end

  test "its own pairing's broadcast does not reload the page again", %{conn: conn, t: t} do
    view = paired(conn, t)
    assert has_element?(view, "#pairings-title")
    assert render(view) =~ "Round 2"
    # The click's own reload, and no second one for its broadcast.
    assert reloads() == 1

    send(view.pid, {:tournament_changed, t.id, :rounds})
    _ = :sys.get_state(view.pid)
    assert reloads() == 0
  end

  test "a write by anybody else since then still reloads it", %{conn: conn, t: t} do
    view = paired(conn, t)
    _ = reloads()

    [board | _] =
      Repo.all(
        from p in Pairing,
          join: r in assoc(p, :round),
          where: r.tournament_id == ^t.id and r.number == 2 and not is_nil(p.black_player_id),
          order_by: p.board
      )

    Repo.update_all(from(p in Pairing, where: p.id == ^board.id), set: [result: "1-0"])
    Tournaments.broadcast_tournament_change(t.id, :rounds)
    _ = :sys.get_state(view.pid)

    assert reloads() == 1
    assert has_element?(view, "#result-select-#{board.id} option[value='1-0'][selected]")
  end

  test "so does a change to the tournament itself", %{conn: conn, t: t} do
    view = paired(conn, t)
    _ = reloads()

    Repo.update_all(from(x in Tournament, where: x.id == ^t.id), set: [name: "Renamed"])
    send(view.pid, {:tournament_changed, t.id, :rounds})
    _ = :sys.get_state(view.pid)

    assert reloads() == 1
    assert render(view) =~ "Renamed"
  end
end
