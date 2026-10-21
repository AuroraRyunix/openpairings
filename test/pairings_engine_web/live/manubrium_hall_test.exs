defmodule PairingsEngineWeb.ManubriumHallTest do
  @moduledoc """
  Manubrium phase 2's hall view (docs/manubrium.md): playing or finished,
  the round clock and where it counts from, search, "my boards", two
  entries that disagree, what the board in the hall saw - and the incident
  photo's whole way from the queue to the desk.
  """
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest
  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Audit, Incidents, Mobile, Repo, Tournaments}
  alias PairingsEngine.Accounts.Scope
  alias PairingsEngine.BoardLink.Game
  alias PairingsEngine.Incidents.{Incident, Photo}
  alias PairingsEngine.Mobile.Sync
  alias PairingsEngine.Tournaments.{Pairing, Round}

  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0>> <> :binary.copy("x", 64)

  defp tournament(scope) do
    {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "Hall T", "type" => "swiss"})
    t
  end

  defp boards(t, n, results \\ %{}, round_attrs \\ %{}) do
    round =
      Repo.insert!(struct!(%Round{tournament_id: t.id, number: 1, status: "paired"}, round_attrs))

    for board <- 1..n do
      {:ok, w} = Tournaments.create_player(t.id, %{"name" => "White#{board}"})
      {:ok, b} = Tournaments.create_player(t.id, %{"name" => "Black#{board}"})

      Repo.insert!(%Pairing{
        round_id: round.id,
        board: board,
        white_player_id: w.id,
        black_player_id: b.id,
        result: Map.get(results, board, ""),
        game_uid: "g#{t.id}-#{board}"
      })
    end
  end

  defp phone(conn, t, opts) do
    {:ok, e} = Mobile.create_enrollment(t.id, opts)
    {init_test_session(conn, %{mobile_enrollment_id: e.id}), e}
  end

  defp result_entry(e, p, result, expected) do
    %{
      "cid" => Ecto.UUID.generate(),
      "enrollment" => e.id,
      "kind" => "result",
      "round" => 1,
      "pairing" => p.id,
      "board" => p.board,
      "white" => p.white_player_id,
      "black" => p.black_player_id,
      "result" => result,
      "expected" => expected
    }
  end

  defp incident_entry(e, p, type, extra \\ %{}) do
    Map.merge(
      %{
        "cid" => Ecto.UUID.generate(),
        "enrollment" => e.id,
        "kind" => "incident",
        "round" => 1,
        "pairing" => p.id,
        "board" => p.board,
        "type" => type,
        "note" => ""
      },
      extra
    )
  end

  describe "the boards" do
    test "say whether they are playing or finished", %{conn: conn} do
      t = tournament(user_scope_fixture())
      [open, done] = boards(t, 2, %{2 => "1-0"})
      {conn, _e} = phone(conn, t, level: "deputy")

      {:ok, lv, _} = live(conn, ~p"/m/results")
      lv |> element("button[phx-click='toggle_show_all']") |> render_click()

      assert has_element?(lv, "#mobile-board-#{open.id}-status.playing")
      assert has_element?(lv, "#mobile-board-#{done.id}-status.finished")
    end

    test "are found by name or by number, finished ones included", %{conn: conn} do
      t = tournament(user_scope_fixture())
      [b1, b2, b3] = boards(t, 3, %{3 => "0-1"})
      {conn, _e} = phone(conn, t, level: "deputy")
      {:ok, lv, _} = live(conn, ~p"/m/results")

      lv |> form("#hall-search", %{"q" => "black2"}) |> render_change()
      assert has_element?(lv, "#mobile-board-#{b2.id}")
      refute has_element?(lv, "#mobile-board-#{b1.id}")

      lv |> form("#hall-search", %{"q" => "3"}) |> render_change()
      assert has_element?(lv, "#mobile-board-#{b3.id}")
      refute has_element?(lv, "#mobile-board-#{b2.id}")

      lv |> form("#hall-search", %{"q" => "nobody"}) |> render_change()
      refute has_element?(lv, "[data-pairing]")
    end

    test "an arbiter's own boards are one tap away", %{conn: conn} do
      owner = user_scope_fixture()
      t = tournament(owner)
      [b1, _b2, b3] = boards(t, 3)
      arbiter = user_fixture()
      {:ok, c} = Tournaments.add_collaborator(owner, t, arbiter.email, "arbiter")
      {:ok, _} = Tournaments.accept_invitation(Scope.for_user(arbiter), c.invite_token)
      {:ok, _} = Tournaments.assign_boards(owner, t, c.id, {3, 3})

      {conn, _e} = phone(conn, t, user_id: arbiter.id)
      {:ok, lv, _} = live(conn, ~p"/m/results")

      assert has_element?(lv, "#hall-mine", "3-3")
      lv |> element("#hall-mine") |> render_click()
      assert has_element?(lv, "#mobile-board-#{b3.id}")
      refute has_element?(lv, "#mobile-board-#{b1.id}")
    end

    test "a no-account phone has no \"my boards\"", %{conn: conn} do
      t = tournament(user_scope_fixture())
      boards(t, 2)
      {conn, _e} = phone(conn, t, level: "deputy")
      {:ok, lv, _} = live(conn, ~p"/m/results")

      refute has_element?(lv, "#hall-mine")
    end

    test "the screen and one-handed switches are there for the phone to run", %{conn: conn} do
      t = tournament(user_scope_fixture())
      boards(t, 1)
      {conn, _e} = phone(conn, t, level: "helper")
      {:ok, lv, _} = live(conn, ~p"/m/results")

      assert has_element?(lv, "#manubrium-toggles[phx-update='ignore'] [data-mq-wake]")
      assert has_element?(lv, "#manubrium-toggles [data-mq-hand]")
    end
  end

  describe "the round clock" do
    test "counts from the publish time, and says so", %{conn: conn} do
      t = tournament(user_scope_fixture())
      published = DateTime.utc_now() |> DateTime.add(-75, :minute) |> DateTime.truncate(:second)
      boards(t, 1, %{}, %{published_at: published})
      {conn, _e} = phone(conn, t, level: "helper")

      {:ok, lv, _} = live(conn, ~p"/m/results")
      assert has_element?(lv, "#round-clock", "1 h 15 min")
      assert has_element?(lv, "#round-clock", "published")
    end

    test "falls back to the first board report, and says so", %{conn: conn} do
      t = tournament(user_scope_fixture())
      [p] = boards(t, 1)
      first = DateTime.utc_now() |> DateTime.add(-20, :minute) |> DateTime.truncate(:second)

      Repo.insert!(%Game{
        tournament_id: t.id,
        game_uid: p.game_uid,
        status: "live",
        first_reported_at: first,
        reported_at: first
      })

      {conn, _e} = phone(conn, t, level: "helper")
      {:ok, lv, _} = live(conn, ~p"/m/results")
      assert has_element?(lv, "#round-clock", "20 min")
      assert has_element?(lv, "#round-clock", "first board reported")
    end

    test "has nothing to say without either", %{conn: conn} do
      t = tournament(user_scope_fixture())
      boards(t, 1)
      {conn, _e} = phone(conn, t, level: "helper")
      {:ok, lv, _} = live(conn, ~p"/m/results")
      refute has_element?(lv, "#round-clock")
    end
  end

  describe "the board in the hall" do
    test "its result stands beside the entered one, red when they differ", %{conn: conn} do
      t = tournament(user_scope_fixture())
      [agree, differ, pending] = boards(t, 3, %{1 => "1-0", 2 => "0-1"})

      for {p, result} <- [{agree, "1-0"}, {differ, "1-0"}, {pending, "1/2-1/2"}] do
        Repo.insert!(%Game{
          tournament_id: t.id,
          game_uid: p.game_uid,
          status: "finished",
          result: result,
          moves: ["e4"]
        })
      end

      {conn, _e} = phone(conn, t, level: "deputy")
      {:ok, lv, _} = live(conn, ~p"/m/results")
      lv |> element("button[phx-click='toggle_show_all']") |> render_click()

      assert has_element?(lv, "#mobile-board-#{agree.id}-report.match")
      assert has_element?(lv, "#mobile-board-#{differ.id}-report.mismatch", "check it")
      assert has_element?(lv, "#mobile-board-#{pending.id}-report.pending")

      # Shown, never entered.
      assert Repo.get!(Pairing, pending.id).result == ""
    end

    test "nothing is drawn for a tournament without live boards", %{conn: conn} do
      t = tournament(user_scope_fixture())
      [p] = boards(t, 1)
      {conn, _e} = phone(conn, t, level: "deputy")
      {:ok, lv, _} = live(conn, ~p"/m/results")
      refute has_element?(lv, "#mobile-board-#{p.id}-report")
    end
  end

  describe "two entries that disagree" do
    test "the second is refused, and both phones are told", %{conn: conn} do
      t = tournament(user_scope_fixture())
      [p] = boards(t, 1)
      {conn_a, a} = phone(conn, t, level: "deputy", label: "Hall A")
      {conn_b, b} = phone(build_conn(), t, level: "deputy", label: "Hall B")

      {:ok, lv_a, _} = live(conn_a, ~p"/m/results")
      {:ok, lv_b, _} = live(conn_b, ~p"/m/results")

      assert {:ok, [%{status: :saved}]} = Sync.submit(a.id, [result_entry(a, p, "1-0", "")])

      assert {:ok, [%{status: :refused, reason: :conflict, current: "1-0"}]} =
               Sync.submit(b.id, [result_entry(b, p, "0-1", "")])

      assert Repo.get!(Pairing, p.id).result == "1-0"

      for lv <- [lv_a, lv_b] do
        lv |> element("button[phx-click='toggle_show_all']") |> render_click()
        assert has_element?(lv, "#mobile-conflict-#{p.id}", "0-1 was refused")
      end

      lv_a |> element("#mobile-conflict-#{p.id} button") |> render_click()
      refute has_element?(lv_a, "#mobile-conflict-#{p.id}")
    end

    test "the direct tap checks what the phone showed, too", %{conn: conn} do
      t = tournament(user_scope_fixture())
      [p] = boards(t, 1)
      {conn, _e} = phone(conn, t, level: "deputy")
      {:ok, lv, _} = live(conn, ~p"/m/results")

      # Entered at the desk after this phone drew the board.
      {:ok, _} = Tournaments.update_pairing_result(Repo.get!(Pairing, p.id), "0-1")

      render_hook(lv, "set_result", %{"id" => "#{p.id}", "result" => "1-0", "expected" => ""})

      assert Repo.get!(Pairing, p.id).result == "0-1"
      assert render(lv) =~ "entered elsewhere"
    end

    test "the buttons carry what the board showed", %{conn: conn} do
      t = tournament(user_scope_fixture())
      [p] = boards(t, 1)
      {conn, _e} = phone(conn, t, level: "deputy")
      {:ok, lv, _} = live(conn, ~p"/m/results")

      assert has_element?(
               lv,
               "#mobile-board-#{p.id} button[data-entry='1-0'][phx-value-expected='']"
             )
    end
  end

  describe "incidents" do
    test "the new kinds are offered and accepted; dispute is now complaint" do
      assert Incidents.kinds() ==
               ~w(illegal_move clock device complaint time_added game_rewound arbiter_call other)
    end

    test "a photo travels with the incident and is kept with the tournament" do
      t = tournament(user_scope_fixture())
      [p] = boards(t, 1)
      {:ok, e} = Mobile.create_enrollment(t.id, level: "deputy")

      entry = incident_entry(e, p, "illegal_move", %{"photo" => Base.encode64(@jpeg)})
      assert {:ok, [%{status: :saved}]} = Sync.submit(e.id, [entry])

      [incident] = Repo.all(Incident)
      assert incident.has_photo

      assert %Photo{data: @jpeg, content_type: "image/jpeg"} =
               Incidents.get_photo(t.id, incident.id)
    end

    test "a photo that is not a JPEG, or too large, is refused with the incident" do
      t = tournament(user_scope_fixture())
      [p] = boards(t, 1)
      {:ok, e} = Mobile.create_enrollment(t.id, level: "deputy")

      png = Base.encode64(<<0x89, "PNG", 0, 0, 0, 0>>)
      big = Base.encode64(<<0xFF, 0xD8, 0xFF>> <> :binary.copy("x", Incidents.photo_max()))

      assert {:ok, [%{status: :refused, reason: :not_a_photo}]} =
               Sync.submit(e.id, [incident_entry(e, p, "clock", %{"photo" => png})])

      assert {:ok, [%{status: :refused, reason: :photo_too_large}]} =
               Sync.submit(e.id, [incident_entry(e, p, "clock", %{"photo" => big})])

      assert {:ok, [%{status: :refused, reason: :invalid}]} =
               Sync.submit(e.id, [incident_entry(e, p, "clock", %{"photo" => "not base64!"})])

      assert Repo.all(Incident) == []
      assert Repo.all(Photo) == []
    end

    test "goes in the audit trail, under the arbiter's account when it is theirs" do
      owner = user_scope_fixture()
      t = tournament(owner)
      [p] = boards(t, 1)
      arbiter = user_fixture()
      {:ok, c} = Tournaments.add_collaborator(owner, t, arbiter.email, "arbiter")
      {:ok, _} = Tournaments.accept_invitation(Scope.for_user(arbiter), c.invite_token)
      {:ok, e} = Mobile.create_enrollment(t.id, user_id: arbiter.id)

      assert {:ok, [%{status: :saved}]} =
               Sync.submit(e.id, [incident_entry(e, p, "time_added", %{"note" => "+2 min"})])

      [incident] = Repo.all(Incident)
      assert incident.user_id == arbiter.id

      [row] = Audit.list_for_tournament(t.id) |> Enum.filter(&(&1.action == "incident.logged"))
      assert row.user_id == arbiter.id

      assert PairingsEngineWeb.AuditLive.describe("incident.logged", row.details) =~
               "Time added"
    end

    test "deleting the tournament takes the photo along" do
      owner = user_scope_fixture()
      t = tournament(owner)
      [p] = boards(t, 1)
      {:ok, e} = Mobile.create_enrollment(t.id, level: "deputy")

      {:ok, _} =
        Sync.submit(e.id, [incident_entry(e, p, "clock", %{"photo" => Base.encode64(@jpeg)})])

      Repo.delete!(Repo.get!(PairingsEngine.Tournaments.Tournament, t.id))
      assert Repo.all(Photo) == []
    end
  end

  describe "the photo on the desk" do
    setup :register_and_log_in_user

    setup %{scope: scope} do
      t = tournament(scope)
      [p] = boards(t, 1)
      {:ok, e} = Mobile.create_enrollment(t.id, level: "deputy")

      {:ok, _} =
        Sync.submit(e.id, [incident_entry(e, p, "clock", %{"photo" => Base.encode64(@jpeg)})])

      %{tournament: t, incident: Repo.one!(Incident)}
    end

    test "is on the incidents page, and served to the desk only", %{
      conn: conn,
      tournament: t,
      incident: i
    } do
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/incidents")
      assert has_element?(lv, "#incident-photo-#{i.id} img")

      photo = get(conn, ~p"/t/#{t.id}/incidents/#{i.id}/photo")
      assert response(photo, 200) == @jpeg
      assert get_resp_header(photo, "content-type") == ["image/jpeg"]
      assert get_resp_header(photo, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(photo, "cache-control") == ["private, no-store"]
    end

    test "is a 404 to anyone else, an arbiter included", %{tournament: t, incident: i} do
      stranger = user_fixture()
      conn = build_conn() |> log_in_user(stranger) |> get(~p"/t/#{t.id}/incidents/#{i.id}/photo")
      assert conn.status == 404

      signed_out = build_conn() |> get(~p"/t/#{t.id}/incidents/#{i.id}/photo")
      assert redirected_to(signed_out) =~ "/users/log-in"

      owner = Scope.for_user(Repo.get!(PairingsEngine.Accounts.User, t.user_id))
      arbiter = user_fixture()
      {:ok, c} = Tournaments.add_collaborator(owner, t, arbiter.email, "arbiter")
      {:ok, _} = Tournaments.accept_invitation(Scope.for_user(arbiter), c.invite_token)

      as_arbiter =
        build_conn() |> log_in_user(arbiter) |> get(~p"/t/#{t.id}/incidents/#{i.id}/photo")

      assert as_arbiter.status == 404
    end
  end

  describe "the desk's Phone QR dialog" do
    setup :register_and_log_in_user

    defp local_mode(on?) do
      previous = Application.get_env(:pairings_engine, :local_mode)
      Application.put_env(:pairings_engine, :local_mode, on?)

      on_exit(fn ->
        if on?, do: PairingsEngineWeb.PhoneLan.switch(false)
        Application.delete_env(:pairings_engine, :board_lan_addresses)

        case previous do
          nil -> Application.delete_env(:pairings_engine, :local_mode)
          value -> Application.put_env(:pairings_engine, :local_mode, value)
        end
      end)
    end

    defp spare_port do
      {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(socket)
      :gen_tcp.close(socket)
      port
    end

    test "gives arbiters their boards", %{conn: conn, scope: scope} do
      local_mode(false)
      t = tournament(scope)
      boards(t, 1)
      arbiter = user_fixture()
      {:ok, c} = Tournaments.add_collaborator(scope, t, arbiter.email, "arbiter")
      {:ok, _} = Tournaments.accept_invitation(Scope.for_user(arbiter), c.invite_token)

      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/pairings")
      lv |> element("#phone-qr-link") |> render_click()
      assert has_element?(lv, "#phone-qr-arbiters")

      lv
      |> form("#assign-boards-#{c.id}", %{"board_from" => "5", "board_to" => "9"})
      |> render_submit()

      assert Tournaments.assigned_boards(arbiter.id, t.id) == {5, 9}
    end

    test "on a desktop copy, the switch opens the way and the code points at it", %{
      conn: conn,
      scope: scope
    } do
      local_mode(true)
      Application.put_env(:pairings_engine, :board_lan_addresses, ["127.0.0.1"])
      PairingsEngine.Meta.delete(Mobile.lan_key())
      t = tournament(scope)
      boards(t, 1)

      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/pairings")
      lv |> element("#phone-qr-link") |> render_click()
      refute has_element?(lv, "#phone-qr-enroll-form")

      lv |> element("#phone-lan-switch") |> render_click()
      port = spare_port()

      lv
      |> form("#phone-lan-form", %{"address" => "127.0.0.1", "port" => "#{port}"})
      |> render_submit()

      assert has_element?(lv, "#phone-lan-switch[aria-pressed=true]")
      lv |> form("#phone-qr-enroll-form", %{}) |> render_submit()

      assert has_element?(lv, "#phone-qr-enroll-url", "http://127.0.0.1:#{port}/m/e/")
      assert has_element?(lv, "#phone-lan-state", "http://127.0.0.1:#{port}/m")
    end
  end
end
