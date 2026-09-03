defmodule PairingsEngineWeb.HandoffUiTest do
  @moduledoc """
  The three surfaces that drive a hand-off: the row control and the receive
  box on the Tournaments page, the download that locks, and the "bring it
  back" affordance in the banner.

  The thing being guarded is not that the buttons render. It is that each
  screen offers the direction that is actually true of the tournament in
  front of it. A copy that has been handed AWAY and a copy that ARRIVED are
  opposite states which look alike from a distance, and a control that offers
  the wrong one either invites an arbiter to hand off an event that is
  already running elsewhere, or sends them looking for a machine that does
  not have it.
  """
  # async: false: sequential SQLite writes, same as the rest of the
  # tournament-list suite.
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Handoff, Repo, Tournaments}

  setup :register_and_log_in_user

  defp create_tournament(scope, name \\ "Handoff UI") do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => name,
        "type" => "swiss",
        "rounds_count" => "3"
      })

    {:ok, _} = Tournaments.create_player(tournament.id, %{"name" => "Alice"})
    Repo.reload!(tournament)
  end

  # A hand-off envelope produced by a *different* tournament, so receiving it
  # is a genuine arrival rather than a second copy of a row already here.
  defp envelope_from_elsewhere(name \\ "Sent From Elsewhere") do
    other = PairingsEngine.AccountsFixtures.user_fixture()
    sender = PairingsEngine.Accounts.Scope.for_user(other)
    tournament = create_tournament(sender, name)

    {:ok, payload} = Handoff.hand_off(tournament, "the other machine", sender)
    {tournament, payload}
  end

  defp upload_json(lv, upload_name, payload) do
    entry =
      file_input(lv, "#" <> form_id(upload_name), upload_name, [
        %{
          name: "payload.json",
          content: Jason.encode!(payload),
          type: "application/json"
        }
      ])

    render_upload(entry, "payload.json")
    entry
  end

  defp form_id(:handoff), do: "handoff-receive-form"
  defp form_id(:handoff_return), do: "handoff-return-form"

  ## -------------------------------------------------------------------------

  describe "the row control offers the direction that is true" do
    test "a live tournament is offered a hand-off", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "Hand off"
      refute html =~ "Bring it back"
      refute html =~ ~s(phx-value-id="#{tournament.id}" ) <> "phx-click=\"return_start\""
    end

    test "a handed-off tournament is offered only the way back", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, _} = Handoff.hand_off(tournament, "the club laptop", scope)

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "Bring it back"
      assert html =~ "handed off"

      # And nothing that would let this copy be handed off a second time, or
      # archived while it is somewhere else.
      refute html =~ "handoff_start"
      refute html =~ "archive_tournament"
    end

    test "a received copy is offered 'Give back', not 'Hand off'", %{conn: conn, scope: scope} do
      {_source, payload} = envelope_from_elsewhere()
      {:ok, _copy} = Handoff.receive(payload, scope)

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "Give back"
      assert html =~ "on loan"
      refute html =~ "Bring it back"
    end
  end

  describe "the hand-off modal" do
    test "warns what is lost, and posts to the route that locks", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/")
      html = lv |> element(~s(button[phx-click="handoff_start"])) |> render_click()

      assert html =~ "read-only on this machine"
      assert html =~ "Helper phones"
      assert html =~ "invitation they have to accept again"

      # A POST, because it locks. A GET would be fired by a link prefetch.
      assert html =~ ~s(action="/t/#{tournament.id}/export/handoff")
      assert html =~ ~s(method="post")
      assert html =~ "_csrf_token"
    end

    test "a received copy's modal leads with giving it back to where it came from", %{
      conn: conn,
      scope: scope
    } do
      {_source, payload} = envelope_from_elsewhere()
      {:ok, copy} = Handoff.receive(payload, scope)

      {:ok, lv, _html} = live(conn, ~p"/")
      html = lv |> element(~s(button[phx-click="handoff_start"])) |> render_click()

      assert html =~ ~s(action="/t/#{copy.id}/export/handoff/return")
      assert html =~ "Give it back to"

      # Handing it on to a third machine stays possible, and says so.
      assert html =~ "send it on to a third machine"
    end
  end

  describe "the download that locks" do
    test "POSTing the hand-off route locks the tournament and returns the file", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      conn =
        post(conn, ~p"/t/#{tournament.id}/export/handoff", %{
          "handoff" => %{"to" => "the club laptop"}
        })

      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert disposition =~ "handoff-ui-handoff.json"

      payload = conn |> response(200) |> Jason.decode!()
      locked = Repo.reload!(tournament)

      assert Tournaments.handed_off?(locked)
      assert payload["handoff"]["token"] == locked.handoff_token
      assert payload["handoff"]["direction"] == "out"
    end

    test "a blank destination locks nothing and says why", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      conn = post(conn, ~p"/t/#{tournament.id}/export/handoff", %{"handoff" => %{"to" => "  "}})

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Say where the tournament is going"
      refute Repo.reload!(tournament).handed_off_at
    end

    test "handing off twice is refused, and the first token survives", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, _} = Handoff.hand_off(tournament, "laptop A", scope)
      token = Repo.reload!(tournament).handoff_token

      conn =
        post(conn, ~p"/t/#{tournament.id}/export/handoff", %{"handoff" => %{"to" => "laptop B"}})

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "already been handed off"
      reloaded = Repo.reload!(tournament)
      assert reloaded.handed_off_to == "laptop A"
      assert reloaded.handoff_token == token
    end

    test "another user's tournament 404s, exactly like every other export", %{conn: conn} do
      {tournament, _payload} = envelope_from_elsewhere("Not Yours")

      assert_raise Ecto.NoResultsError, fn ->
        post(conn, ~p"/t/#{tournament.id}/export/handoff", %{"handoff" => %{"to" => "here"}})
      end
    end

    test "returning a received copy downloads the file that unlocks the original", %{
      conn: conn,
      scope: scope
    } do
      {source, payload} = envelope_from_elsewhere()
      {:ok, copy} = Handoff.receive(payload, scope)

      conn = post(conn, ~p"/t/#{copy.id}/export/handoff/return")

      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "-return.json"

      returned = conn |> response(200) |> Jason.decode!()
      assert returned["handoff"]["direction"] == "back"
      assert returned["handoff"]["token"] == Repo.reload!(source).handoff_token

      # And this copy is parked - no instant with two live copies.
      assert Tournaments.handed_off?(Repo.reload!(copy))
    end

    test "a tournament that never arrived by hand-off cannot be given back", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      conn = post(conn, ~p"/t/#{tournament.id}/export/handoff/return")

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "nothing to give back"
      refute Repo.reload!(tournament).handed_off_at
    end
  end

  describe "receiving a hand-off" do
    test "the box takes the file and the tournament lands live here", %{
      conn: conn,
      scope: _scope
    } do
      {_source, payload} = envelope_from_elsewhere()

      {:ok, lv, _html} = live(conn, ~p"/")
      lv |> element(~s(button[phx-click="receive_handoff"])) |> render_click()

      entry = upload_json(lv, :handoff, payload)
      html = lv |> form("#handoff-receive-form") |> render_submit()
      _ = entry

      assert html =~ "is now live on this machine"
      assert html =~ "re-enrol their phones"
      assert html =~ "Sent From Elsewhere"
    end

    test "an ordinary backup is refused, and pointed at the right box", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      backup = PairingsEngine.TournamentExport.export_tournament(tournament)

      {:ok, lv, _html} = live(conn, ~p"/")
      lv |> element(~s(button[phx-click="receive_handoff"])) |> render_click()

      upload_json(lv, :handoff, backup)
      html = lv |> form("#handoff-receive-form") |> render_submit()

      assert html =~ "not a hand-off file"
      assert html =~ "Import backup"
    end

    test "the same file twice is refused the second time", %{conn: conn} do
      {_source, payload} = envelope_from_elsewhere()

      {:ok, lv, _html} = live(conn, ~p"/")
      lv |> element(~s(button[phx-click="receive_handoff"])) |> render_click()
      upload_json(lv, :handoff, payload)
      lv |> form("#handoff-receive-form") |> render_submit()

      lv |> element(~s(button[phx-click="receive_handoff"])) |> render_click()
      upload_json(lv, :handoff, payload)
      html = lv |> form("#handoff-receive-form") |> render_submit()

      assert html =~ "two live copies"
    end
  end

  describe "bringing it back" do
    test "the banner links to the box that takes the returning file", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, _} = Handoff.hand_off(tournament, "the club laptop", scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/players")

      assert html =~ "Bring it back"
      assert html =~ "/?return=#{tournament.id}"
    end

    test "following that link opens the box, named after the tournament", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, _} = Handoff.hand_off(tournament, "the club laptop", scope)

      {:ok, _lv, html} = live(conn, ~p"/?return=#{tournament.id}")

      assert html =~ "Bring back &quot;Handoff UI&quot;"
      assert html =~ "the club laptop"

      # What the button actually does, said before it is pressed: this is a
      # wholesale replacement with a restore point behind it.
      assert html =~ "This replaces what is here with what comes back"
      assert html =~ "kept as a restore point"
    end

    test "the returning file unlocks it, brings the event home, and says so", %{
      conn: conn,
      scope: scope
    } do
      # Both ends in one database: hand off to a second account, which
      # receives it, plays some of the event, and gives it back.
      tournament = create_tournament(scope)
      {:ok, out} = Handoff.hand_off(tournament, "the club laptop", scope)

      elsewhere =
        PairingsEngine.Accounts.Scope.for_user(PairingsEngine.AccountsFixtures.user_fixture())

      {:ok, copy} = Handoff.receive(out, elsewhere)
      {:ok, _} = Tournaments.create_player(copy.id, %{"name" => "Signed Up There"})
      {:ok, returning} = Handoff.return(Repo.reload!(copy), elsewhere)

      {:ok, lv, _html} = live(conn, ~p"/?return=#{tournament.id}")
      upload_json(lv, :handoff_return, returning)
      html = lv |> form("#handoff-return-form") |> render_submit()

      assert html =~ "live again"
      assert html =~ "restore point"

      refute Tournaments.handed_off?(Repo.reload!(tournament))
      assert "Signed Up There" in Enum.map(Tournaments.list_players(tournament.id), & &1.name)
    end

    test "a source that was force-unlocked refuses the file and names the way out", %{
      conn: conn,
      scope: scope
    } do
      # The break-glass case: the laptop went missing, the arbiter unlocked
      # this copy without the token and carried on, and then the laptop turned
      # up. Both copies now hold real work and nothing here may choose.
      tournament = create_tournament(scope)
      {:ok, out} = Handoff.hand_off(tournament, "the club laptop", scope)

      elsewhere =
        PairingsEngine.Accounts.Scope.for_user(PairingsEngine.AccountsFixtures.user_fixture())

      {:ok, copy} = Handoff.receive(out, elsewhere)
      {:ok, _} = Tournaments.force_take_back(Repo.reload!(tournament), scope)
      {:ok, _} = Tournaments.create_player(tournament.id, %{"name" => "Played Here"})
      {:ok, returning} = Handoff.return(Repo.reload!(copy), elsewhere)

      # The panel only opens for a tournament that is checked out, so the
      # sequence that reaches it is the realistic one: having broken the lock
      # and carried on, the arbiter handed the event to a second laptop - and
      # then the first one turned up.
      {:ok, _} = Handoff.hand_off(Repo.reload!(tournament), "a second laptop", scope)

      {:ok, lv, _html} = live(conn, ~p"/?return=#{tournament.id}")
      upload_json(lv, :handoff_return, returning)
      html = lv |> form("#handoff-return-form") |> render_submit()

      assert html =~ "Both are real work and nothing here can merge them"
      assert html =~ "as a separate tournament"

      assert Tournaments.handed_off?(Repo.reload!(tournament))
      assert "Played Here" in Enum.map(Tournaments.list_players(tournament.id), & &1.name)
    end

    test "the OUTBOUND file is refused, though it carries the same token", %{
      conn: conn,
      scope: scope
    } do
      # The mistake this guard exists for: two similarly named files, and the
      # wrong one unlocks this copy while the other machine is still running
      # the event.
      tournament = create_tournament(scope)
      {:ok, out} = Handoff.hand_off(tournament, "the club laptop", scope)

      {:ok, lv, _html} = live(conn, ~p"/?return=#{tournament.id}")
      upload_json(lv, :handoff_return, out)
      html = lv |> form("#handoff-return-form") |> render_submit()

      assert html =~ "the file you sent OUT"
      assert Tournaments.handed_off?(Repo.reload!(tournament))
    end

    test "a returning file for a different tournament is refused", %{conn: conn, scope: scope} do
      mine = create_tournament(scope, "Mine")
      {:ok, _} = Handoff.hand_off(mine, "the club laptop", scope)

      # A perfectly valid return, for somebody else's event.
      {_other_source, out} = envelope_from_elsewhere("Theirs")

      elsewhere =
        PairingsEngine.Accounts.Scope.for_user(PairingsEngine.AccountsFixtures.user_fixture())

      {:ok, other_copy} = Handoff.receive(out, elsewhere)
      {:ok, wrong_return} = Handoff.return(other_copy, elsewhere)

      {:ok, lv, _html} = live(conn, ~p"/?return=#{mine.id}")
      upload_json(lv, :handoff_return, wrong_return)
      html = lv |> form("#handoff-return-form") |> render_submit()

      # Refused on identity, before the contents are touched: a valid return
      # for another event would otherwise replace this one with it.
      assert html =~ "Applying it would replace what is here with another event"
      assert Tournaments.handed_off?(Repo.reload!(mine))
      assert Enum.map(Tournaments.list_players(mine.id), & &1.name) == ["Alice"]
    end

    test "a ?return for a tournament that is not handed off opens nothing", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/?return=#{tournament.id}")

      refute html =~ "handoff-return-form"
    end

    test "a ?return naming somebody else's tournament opens nothing", %{conn: conn} do
      {tournament, _payload} = envelope_from_elsewhere("Not Yours Either")

      {:ok, _lv, html} = live(conn, ~p"/?return=#{tournament.id}")

      refute html =~ "handoff-return-form"
    end

    test "a ?return with junk in it opens nothing rather than crashing", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/?return=not-a-number")

      refute html =~ "handoff-return-form"
    end
  end
end
