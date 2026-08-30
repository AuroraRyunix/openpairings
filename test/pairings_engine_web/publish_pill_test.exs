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
        last_published_at: nil,
        last_publish_bytes: nil
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
    #
    # Scoped to the pill deliberately. The panel behind it renders the full
    # indicator, which shows a round trip whenever there is one - and for a
    # REFUSED server that is the useful reading: reached in 40 ms, and it
    # said no. `Publishing.status/0` never pairs :unreachable with a latency
    # anyway; this pairing exists only in this test.
    {:ok, lv, _html} = live(conn, ~p"/")

    broadcast(status(%{state: :unreachable, latency_ms: 40}))

    refute lv |> element("summary.pub-pill .pub-ms") |> has_element?()
  end

  test "before the first check it says so, rather than guessing", %{conn: conn} do
    # Guessing green would be corrected a second later; guessing red would
    # put a scare on an installation that is fine.
    {:ok, _lv, html} = live(conn, ~p"/")

    assert html =~ "Checking"
  end

  test "it opens the full status in place rather than navigating away", %{conn: conn} do
    # It used to `navigate` to /fide - the rating-list page, which has
    # nothing to do with publishing. There is no global publishing page it
    # could have meant instead; the settings that matter are per-tournament,
    # and this pill is on every page including ones with no tournament.
    #
    # So clicking a status light gives MORE STATUS, in place.
    {:ok, lv, _html} = live(conn, ~p"/")

    broadcast(status(%{state: :unreachable, message: "Could not reach the results site."}))

    refute lv |> element("a.pub-pill") |> has_element?()
    assert lv |> element("details.pub-menu summary.pub-pill") |> has_element?()
    assert lv |> element("details.pub-menu .pub-panel .conn-status") |> has_element?()

    # The reason, in words, is inside the panel - which is the thing the pill
    # has never had room for.
    assert render(lv) =~ "Could not reach the results site."
  end

  test "it shares the popover group with the other top-bar menus", %{conn: conn} do
    # `<details name>` makes them mutually exclusive, so opening the status
    # closes Advanced and Settings rather than stacking two panels.
    {:ok, lv, _html} = live(conn, ~p"/")

    broadcast(status(%{}))

    assert lv |> element(~s|details.pub-menu[name="topbar-popover"]|) |> has_element?()
  end

  test "the panel says how big the last published document was", %{conn: conn} do
    # A snapshot is the whole tournament rather than a delta, so this is the
    # one number that says what a round costs to publish - and it moves: the
    # tie-break working multiplied it by about 3.4 on a large event.
    {:ok, lv, _html} = live(conn, ~p"/")

    broadcast(status(%{last_publish_bytes: 597_412, last_published_at: DateTime.utc_now()}))

    assert render(lv) =~ "583.4 KB"
  end

  test "and says nothing about size when nothing has been sent", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/")

    broadcast(status(%{last_publish_bytes: nil}))

    refute render(lv) =~ "last sent"
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

  describe "the panel's copy" do
    # Rendered from the exact state the live box showed on 2026-08-30, which
    # read:
    #
    #   Connected  2 ms
    #   Connected. The address and token are both accepted.
    #   localhost  last sent just now  82.0 KB last sent
    #
    # Three faults in four lines: the state said twice, the words "last sent"
    # said twice, and three separate facts run together with no separator.
    defp panel(conn, attrs) do
      {:ok, lv, _html} = live(conn, ~p"/")
      broadcast(status(attrs))

      lv
      |> render()
      |> String.replace(~r/<[^>]+>/, " ")
      |> String.replace(~r/\s+/, " ")
    end

    test "the size and the time are one phrase, not two", %{conn: conn} do
      text =
        panel(conn, %{last_publish_bytes: 83_968, last_published_at: DateTime.utc_now()})

      assert text =~ "82.0 KB sent just now"
      refute text =~ "last sent just now"
    end

    test "the message does not repeat the headline above it", %{conn: conn} do
      text =
        panel(conn, %{
          state: :connected,
          message: "Connected. The address and token are both accepted."
        })

      assert text =~ "The address and token are both accepted."
      # "Connected" once, as the headline - not again to open the sentence.
      refute text =~ "Connected. The address"
    end

    test "a message that does not echo the headline is shown whole", %{conn: conn} do
      # Trimming on a guess would eat real text.
      text = panel(conn, %{state: :refused, message: "Reached the server, but it said no."})

      assert text =~ "Reached the server, but it said no."
    end

    test "the facts are separated rather than run together", %{conn: conn} do
      text =
        panel(conn, %{
          endpoint: "http://localhost:4004",
          last_publish_bytes: 83_968,
          last_published_at: DateTime.utc_now()
        })

      assert text =~ "localhost"
      assert text =~ "82.0 KB sent just now"
      # The separator is CSS, so the markup keeps them as distinct spans
      # rather than one run of words.
      assert text =~ ~r/localhost\s*<?/
    end

    test "no size yet falls back to the time rather than inventing one", %{conn: conn} do
      text = panel(conn, %{last_publish_bytes: nil, last_published_at: DateTime.utc_now()})

      assert text =~ "last sent just now"
      refute text =~ "KB sent"
    end
  end

  describe "the stability line is one fact, not a paragraph" do
    # It read: "Steady for the last 10 minutes. Slowest check 4 ms. No drops
    # since this app started 3 days ago." Three sentences to say "fine".
    test "a steady connection says only the slowest check", %{conn: conn} do
      # The Monitor is not running in test, so `stability/0` answers nil and
      # the line is absent entirely - which is itself the behaviour under
      # four checks. Asserted here so a future default that renders an empty
      # window does not slip in.
      {:ok, lv, _html} = live(conn, ~p"/")
      broadcast(status(%{}))

      refute render(lv) =~ "Steady for the last"
      refute render(lv) =~ "No drops since this app started"
    end
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
