defmodule PairingsEngineWeb.PublishPillTest do
  @moduledoc """
  The top-bar publishing indicator.

  It exists because publishing is deliberately invisible - queued, retried,
  never in the way of pairing a round - and the cost of that is an arbiter
  having no way to tell "results are going out" from "nothing has left this
  laptop since Tuesday". Both look like nothing happening.

  So what is tested is that the answer reaches the top bar of an ordinary
  page without that page asking for it, and that each state says a different
  thing in WORDS. Colour is not the answer on its own: it is unreadable to a
  colourblind arbiter and ambiguous to everyone at a glance.
  """
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.Publishing

  setup :register_and_log_in_user

  # Seeded straight into the Monitor's cache rather than by waiting for a
  # poll: the poller is disabled in test on purpose, and waiting on a real
  # network check would be slow and flaky for no gain. It calls the same
  # function the Monitor itself does, so this exercises both halves - the
  # table the top bar reads, and the broadcast that makes it move.
  defp broadcast(status) do
    PairingsEngine.Publishing.Monitor.put_status(status)
  end

  setup do
    on_exit(fn -> PairingsEngine.Publishing.Monitor.clear() end)
    :ok
  end

  defp status(attrs) do
    Map.merge(
      %{
        state: :connected,
        message: "Connected. The address and token are both accepted.",
        latency_ms: 40,
        endpoint: "https://openresults.example",
        pending: 0,
        last_published_at: nil
      },
      attrs
    )
  end

  test "is on an ordinary page, not only the settings screen", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/")

    broadcast(status(%{}))

    html = render(lv)
    assert html =~ "pub-pill"
    assert html =~ "Live"
    assert html =~ "40 ms"
  end

  test "says a different word for each state", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/")

    for {attrs, word} <- [
          {%{state: :connected, pending: 0}, "Live"},
          {%{state: :connected, pending: 3}, "Sending"},
          {%{state: :refused}, "Refused"},
          {%{state: :unreachable}, "Offline"},
          {%{state: :unconfigured}, "Not publishing"}
        ] do
      broadcast(status(attrs))
      assert render(lv) =~ word
    end
  end

  test "a queue that is not empty reads as sending, however good the connection is", %{conn: conn} do
    # "Connected, and eight tournaments are still waiting" is not a green
    # situation, and this is the state the whole indicator was asked for: an
    # arbiter enters the last result of a round and wants to see movement.
    {:ok, lv, _html} = live(conn, ~p"/")

    broadcast(status(%{state: :connected, pending: 8}))
    html = render(lv)

    assert html =~ "is-busy"
    assert html =~ "Sending"
    refute html =~ ">Live<"
  end

  test "the latency is shown only when the connection is up", %{conn: conn} do
    # An "Offline" pill with a millisecond count beside it is a contradiction
    # somebody has to stop and resolve.
    {:ok, lv, _html} = live(conn, ~p"/")

    broadcast(status(%{state: :unreachable, latency_ms: 40}))

    refute render(lv) =~ "40 ms"
  end

  test "before the first check it says so, rather than guessing", %{conn: conn} do
    # Guessing green would be corrected a second later; guessing red would
    # put a scare on an installation that is fine.
    {:ok, _lv, html} = live(conn, ~p"/")

    assert html =~ "Checking"
  end

  test "it links to the page that can fix it", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/")

    broadcast(status(%{state: :unreachable}))

    assert lv |> element("a.pub-pill[href='/fide']") |> has_element?()
  end

  test "the pill's message survives a page that defines its own handle_info", %{
    conn: conn,
    user: user
  } do
    # The hook halts its own message rather than passing it on. A LiveView
    # with no matching clause would crash; one with a catch-all would swallow
    # it, which has already been a bug in this codebase once.
    # Connections is role-gated now, and it is still the right page for this:
    # it defines several handle_info clauses of its own, which is the thing
    # being proven safe.
    {:ok, admin} = PairingsEngine.Accounts.set_role(user.email, "admin")
    {:ok, lv, _html} = live(log_in_user(conn, admin), ~p"/fide")

    broadcast(status(%{state: :connected, pending: 2}))

    assert render(lv) =~ "Sending"
  end

  describe "the Monitor" do
    test "is disabled in test, and status/0 answers nil rather than raising" do
      # Every page reads this. If it raised when the poller had not answered
      # yet - or was not running - it would take the top bar, and with it
      # every page, down at once.
      assert Publishing.Monitor.status() == nil
    end
  end
end
