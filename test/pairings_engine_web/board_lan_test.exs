defmodule PairingsEngineWeb.BoardLanTest do
  @moduledoc """
  "Let boards on this network connect" (`PairingsEngineWeb.BoardLan`): a
  desktop copy's second listener, which answers the board link and nothing
  else.

  The listener is started for real, on a spare port of 127.0.0.1, and asked
  over HTTP - "only the board link answers there" is a claim about a socket,
  and a test that calls a function would be testing something else. The
  machine's "network addresses" are handed in (`:board_lan_addresses`), so
  no test depends on which networks the machine running it is on.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import PairingsEngine.BoardLinkFixtures

  alias PairingsEngine.{Audit, BoardLink, Meta, RateLimit, Repo}
  alias PairingsEngine.BoardLink.Link
  alias PairingsEngineWeb.BoardLan

  @supervisor PairingsEngineWeb.BoardLan.Supervisor

  setup :register_and_log_in_user

  setup %{scope: scope} do
    paired_tournament(scope)
  end

  # A port nothing is on: asked of the system, used a moment later.
  defp spare_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp desktop(_context \\ %{}) do
    previous = Application.get_env(:pairings_engine, :local_mode)
    Application.put_env(:pairings_engine, :local_mode, true)
    Application.put_env(:pairings_engine, :board_lan_addresses, ["127.0.0.1"])

    on_exit(fn ->
      # While the mode is still on, so the switch can still be reached, and
      # before the sandbox goes (callbacks run newest first).
      BoardLan.switch(false)
      Application.delete_env(:pairings_engine, :board_lan_addresses)

      case previous do
        nil -> Application.delete_env(:pairings_engine, :local_mode)
        value -> Application.put_env(:pairings_engine, :local_mode, value)
      end
    end)

    port = spare_port()
    {:ok, _} = BoardLan.switch(true)
    {:ok, status} = BoardLan.choose("127.0.0.1", port)
    %{port: port, status: status}
  end

  defp lan_code!(scope, tournament) do
    %{base_url: base} = BoardLan.status()
    {:ok, link, secret} = BoardLink.create_link(scope, tournament, lan: base)
    # Asking is what makes the listener look again.
    status = BoardLan.status()
    {link, secret, status}
  end

  defp ask(port, path, opts \\ []) do
    {secret, opts} = Keyword.pop(opts, :secret)
    {host, opts} = Keyword.pop(opts, :host, "127.0.0.1")
    headers = if secret, do: [{"authorization", "Bearer " <> secret}], else: []

    Req.request(
      [
        url: "http://#{host}:#{port}#{path}",
        method: :get,
        headers: headers,
        retry: false,
        redirect: false,
        receive_timeout: 5_000,
        connect_options: [timeout: 700]
      ] ++ opts
    )
  end

  defp listeners, do: DynamicSupervisor.count_children(@supervisor).active

  describe "a hosted server" do
    test "has no switch, no listener, and no code for the network", %{
      conn: conn,
      scope: scope,
      tournament: t
    } do
      refute BoardLan.available?()
      assert BoardLan.switch(true) == {:error, :unavailable}
      assert BoardLan.choose("127.0.0.1", 4747) == {:error, :unavailable}
      assert %{available?: false, enabled?: false, state: :off, base_url: nil} = BoardLan.status()
      assert Meta.get("board_lan_enabled") == nil
      assert listeners() == 0

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/boards")
      refute has_element?(lv, "#boards-lan")
      refute has_element?(lv, "#boards-lan-toggle")
      refute has_element?(lv, "#tournament-codes-new-lan")

      # A click nobody could have made, sent anyway.
      render_hook(lv, "lan_switch", %{})
      render_hook(lv, "lan_choose", %{"lan" => %{"address" => "127.0.0.1", "port" => "4747"}})
      assert Meta.get("board_lan_enabled") == nil
      assert listeners() == 0

      # And asking for a network code gets no such thing.
      render_hook(lv, "new_code", %{"scope" => "tournament", "where" => "lan"})
      assert Repo.all(Link) == []

      {:ok, link, secret} = BoardLink.create_link(scope, t, lan: "http://192.168.1.20:4747")
      assert link.reach == nil
      assert link.expires_at == nil
      # The code carries the public address, as it always did.
      assert PairingsEngineWeb.BoardLinkAddress.connect_code(secret) ==
               PairingsEngineWeb.Endpoint.url() <> "/api/boards/v1#" <> secret
    end

    test "the listener's plug answers nothing there, not even the board link", %{
      scope: scope,
      tournament: t
    } do
      {:ok, _link, secret} = BoardLink.create_link(scope, t)

      conn =
        Plug.Test.conn(:get, "/api/boards/v1/link")
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> secret)
        |> BoardLan.Plug.call([])

      assert conn.status == 404
    end
  end

  describe "the switch" do
    setup :desktop

    test "is off until switched on, and on is not yet an open port", %{port: port, status: status} do
      # On, an address and a port chosen - and no code for the network yet.
      assert %{enabled?: true, state: :idle, address: "127.0.0.1", port: ^port} = status
      assert status.base_url == "http://127.0.0.1:#{port}"
      assert listeners() == 0

      assert {:error, %Req.TransportError{}} =
               ask(port, "/api/boards/v1/link")
    end

    test "opens with the first network code and closes with the last", %{
      port: port,
      scope: scope,
      tournament: t
    } do
      {link, secret, status} = lan_code!(scope, t)
      assert status.state == :listening
      assert listeners() == 1
      assert link.reach == "lan"
      assert link.address == "http://127.0.0.1:#{port}"
      # A network code has no date: it works until it is withdrawn.
      assert link.expires_at == nil
      later = DateTime.add(DateTime.utc_now(), 400 * 86_400, :second)
      refute BoardLink.expired?(link, later)

      assert {:ok, %{status: 200, body: %{"api" => 1, "kind" => "tournament"}}} =
               ask(port, "/api/boards/v1/link", secret: secret)

      {:ok, _} = BoardLink.revoke_link(scope, t, link.id)
      assert %{state: :idle} = BoardLan.status()
      assert listeners() == 0
      assert {:error, %Req.TransportError{}} = ask(port, "/api/boards/v1/link", secret: secret)
    end

    test "off and on again at runtime, without anything else restarting", %{
      port: port,
      scope: scope,
      tournament: t
    } do
      {_link, secret, _status} = lan_code!(scope, t)
      endpoint = Process.whereis(PairingsEngineWeb.Endpoint)
      manager = Process.whereis(BoardLan)

      assert {:ok, %{status: 200}} = ask(port, "/api/boards/v1/link", secret: secret)

      assert {:ok, %{enabled?: false, state: :off}} = BoardLan.switch(false)
      assert listeners() == 0
      assert {:error, %Req.TransportError{}} = ask(port, "/api/boards/v1/link", secret: secret)

      assert {:ok, %{enabled?: true, state: :listening}} = BoardLan.switch(true)
      assert {:ok, %{status: 200}} = ask(port, "/api/boards/v1/link", secret: secret)

      assert Process.whereis(PairingsEngineWeb.Endpoint) == endpoint
      assert Process.whereis(BoardLan) == manager
    end

    test "it is remembered: the listener comes back when the program does", %{
      port: port,
      scope: scope,
      tournament: t
    } do
      {_link, secret, _status} = lan_code!(scope, t)
      assert listeners() == 1

      # The process that decides goes down and comes up, as at a restart.
      :ok = Supervisor.terminate_child(PairingsEngine.Supervisor, BoardLan)
      {:ok, _pid} = Supervisor.restart_child(PairingsEngine.Supervisor, BoardLan)
      # Has it finished starting?
      _ = :sys.get_state(BoardLan)

      # Nobody pressed anything.
      assert listeners() == 1
      assert {:ok, %{status: 200}} = ask(port, "/api/boards/v1/link", secret: secret)
      assert %{enabled?: true, state: :listening} = BoardLan.status()
    end

    test "a port another program holds is said, and nothing falls over", %{
      conn: conn,
      scope: scope,
      tournament: t
    } do
      {:ok, held} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, taken} = :inet.port(held)

      assert {:ok, %{state: :port_taken, base_url: nil}} = BoardLan.choose("127.0.0.1", taken)
      assert listeners() == 0
      assert Process.alive?(Process.whereis(BoardLan))

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/boards")
      assert has_element?(lv, "#boards-lan[data-state=port_taken]")
      assert has_element?(lv, "#boards-lan-state[role=alert]", "#{taken}")
      # No code for the network while nothing can answer there.
      refute has_element?(lv, "#tournament-codes-new-lan")
      render_hook(lv, "new_code", %{"scope" => "tournament", "where" => "lan"})
      assert Repo.all(Link) == []

      # Another port, and it works.
      free = spare_port()
      assert {:ok, %{state: :idle}} = BoardLan.choose("127.0.0.1", free)
      {_link, secret, status} = lan_code!(scope, t)
      assert status.state == :listening
      assert {:ok, %{status: 200}} = ask(free, "/api/boards/v1/link", secret: secret)

      :gen_tcp.close(held)
    end

    test "a port that is no port, and this program's own, are refused" do
      assert BoardLan.choose("127.0.0.1", "80") == {:error, :bad_port}
      assert BoardLan.choose("127.0.0.1", "seven") == {:error, :bad_port}
      assert BoardLan.choose("127.0.0.1", 70_000) == {:error, :bad_port}
      own = PairingsEngineWeb.Endpoint.config(:http)[:port]
      assert BoardLan.choose("127.0.0.1", own) == {:error, :bad_port}
      assert BoardLan.choose("10.11.12.13", 4747) == {:error, :not_an_address}
    end
  end

  describe "what answers on the network listener" do
    setup :desktop

    setup %{scope: scope, tournament: t} do
      {link, secret, %{state: :listening}} = lan_code!(scope, t)
      %{link: link, secret: secret}
    end

    test "the board link: all four requests", %{
      port: port,
      secret: secret,
      tournament: t,
      boards: [board1 | _]
    } do
      assert {:ok, %{status: 200}} = ask(port, "/api/boards/v1/link", secret: secret)

      assert {:ok, %{status: 200, body: %{"status" => "ok"}}} =
               ask(port, "/api/boards/v1/box",
                 secret: secret,
                 method: :post,
                 json: %{"name" => "Hall box", "version" => "1.0"}
               )

      assert {:ok, %{status: 200, body: %{"tournament" => _}}} =
               ask(port, "/api/boards/v1/tournaments/#{t.id}", secret: secret)

      assert {:ok, %{status: 200, body: %{"applied" => true}}} =
               ask(port, "/api/boards/v1/tournaments/#{t.id}/games",
                 secret: secret,
                 method: :post,
                 json: report_for(board1)
               )

      assert %{moves: ["e4", "e5", "Nf3"]} = BoardLink.get_game(t.id, board1.game_uid)
    end

    test "and nothing else: every other path is the same 404, code or no code", %{
      port: port,
      secret: secret,
      tournament: t
    } do
      elsewhere = [
        "/",
        "/live",
        "/live/websocket?vsn=2.0.0",
        "/live/longpoll?vsn=2.0.0",
        "/phoenix/live_reload/socket",
        "/favicon.ico",
        "/robots.txt",
        "/assets/app.css",
        "/assets/app.js",
        "/images/logo.svg",
        "/dev/dashboard",
        "/dev/mailbox",
        "/users/log-in",
        "/users/register",
        "/users/settings",
        "/auth/keycloak",
        "/t/#{t.id}/pairings",
        "/t/#{t.id}/settings/boards",
        "/t/#{t.id}/export/json",
        "/export/tournaments.json",
        "/backups/latest",
        "/admin",
        "/fide",
        "/help",
        "/changelog",
        "/tools",
        "/m",
        "/internal/fide/search?q=a",
        "/health",
        "/api",
        "/api/boards",
        "/api/boards/v1",
        "/api/boards/v1/",
        "/api/boards/v2/link",
        "/api/boards/v1/link/more",
        "/api/boards/v1/tournaments",
        "/api/boards/v1/tournaments/#{t.id}/games/1",
        "/api/boards/v1/../../users/log-in",
        "/api/boards/v1/%2e%2e/%2e%2e/",
        "//api/boards/v1/link/.."
      ]

      for path <- elsewhere, secret <- [nil, secret] do
        assert {:ok, response} = ask(port, path, secret: secret)

        assert {path, response.status, response.body} ==
                 {path, 404, %{"error" => "not_found", "detail" => "nothing here"}}

        assert Req.Response.get_header(response, "set-cookie") == []
      end

      # The right paths with the wrong verbs, and the wrong paths with a body.
      for {method, path} <- [
            {:post, "/api/boards/v1/link"},
            {:put, "/api/boards/v1/link"},
            {:delete, "/api/boards/v1/link"},
            {:patch, "/api/boards/v1/tournaments/#{t.id}"},
            {:delete, "/api/boards/v1/tournaments/#{t.id}"},
            {:get, "/api/boards/v1/box"},
            {:get, "/api/boards/v1/tournaments/#{t.id}/games"},
            {:post, "/internal/deploy-notice"},
            {:post, "/internal/notice"},
            {:post, "/users/log-in"},
            {:delete, "/users/log-out"},
            {:post, "/t/#{t.id}/export/handoff"}
          ] do
        assert {:ok, %{status: 404}} = ask(port, path, secret: secret, method: method, json: %{})
      end

      assert {:ok, %{status: 404, body: ""}} =
               ask(port, "/api/boards/v1/link", secret: secret, method: :head)
    end

    test "the launcher's details are not on it, even with the launcher's secret", %{port: port} do
      Application.put_env(:pairings_engine, :launcher_token, "a-launcher-secret-for-this-test")
      on_exit(fn -> Application.delete_env(:pairings_engine, :launcher_token) end)

      assert {:ok, %{status: 404}} =
               Req.get("http://127.0.0.1:#{port}/_launcher/stats",
                 headers: [{"x-launcher-token", "a-launcher-secret-for-this-test"}],
                 retry: false
               )
    end

    test "the arbiter's own listener is untouched by all this", %{conn: conn, tournament: t} do
      # The pages are where they were, for the same signed-in arbiter.
      assert conn |> get(~p"/t/#{t.id}/settings/boards") |> html_response(200)
      assert PairingsEngineWeb.Endpoint.config(:http)[:ip] == {127, 0, 0, 1}
    end

    test "no code is 401, in the board link's own words and nothing more", %{port: port} do
      assert {:ok, %{status: 401, body: body}} = ask(port, "/api/boards/v1/link")
      assert %{"error" => "unauthorized"} = body
      assert Map.keys(body) == ["detail", "error"]
    end

    test "a code for a box on this PC is not accepted from the network", %{
      conn: conn,
      port: port,
      scope: scope,
      tournament: t,
      secret: lan_secret
    } do
      {:ok, here, here_secret} = BoardLink.create_link(scope, t)
      assert here.reach == nil

      assert {:ok, %{status: 401, body: %{"error" => "unauthorized"}}} =
               ask(port, "/api/boards/v1/link", secret: here_secret)

      # On this PC's own listener both are good: same machine, same box.
      for secret <- [here_secret, lan_secret] do
        assert conn
               |> put_req_header("authorization", "Bearer " <> secret)
               |> get(~p"/api/boards/v1/link")
               |> json_response(200)
      end
    end

    test "a network code runs out, and the port closes behind it", %{
      conn: conn,
      port: port,
      link: link,
      secret: secret
    } do
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      link |> Ecto.Changeset.change(expires_at: past) |> Repo.update!()

      assert {:ok, %{status: 401}} = ask(port, "/api/boards/v1/link", secret: secret)

      assert conn
             |> put_req_header("authorization", "Bearer " <> secret)
             |> get(~p"/api/boards/v1/link")
             |> json_response(401)

      assert %{state: :idle} = BoardLan.status()
      assert listeners() == 0
    end

    test "a malformed body is a short no, not a stack trace", %{port: port, secret: secret} do
      assert {:ok, %{status: status, body: body}} =
               ask(port, "/api/boards/v1/box",
                 secret: secret,
                 method: :post,
                 headers: [
                   {"authorization", "Bearer " <> secret},
                   {"content-type", "application/json"}
                 ],
                 body: "{not json"
               )

      assert status == 400
      assert body == %{"error" => "invalid_request", "detail" => "the request could not be read"}
    end
  end

  describe "who is asking" do
    setup :desktop

    defp from(ip, path, headers) do
      conn = %{Plug.Test.conn(:get, path) | remote_ip: ip}

      headers
      |> Enum.reduce(conn, fn {name, value}, conn ->
        Plug.Conn.put_req_header(conn, name, value)
      end)
      |> BoardLan.Plug.call([])
    end

    test "an address that is not a local network's is refused before anything is read", %{
      scope: scope,
      tournament: t
    } do
      {_link, secret, _status} = lan_code!(scope, t)
      auth = [{"authorization", "Bearer " <> secret}]

      for ip <- [
            {8, 8, 8, 8},
            {172, 32, 0, 1},
            {100, 64, 0, 1},
            {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
          ] do
        conn = from(ip, "/api/boards/v1/link", auth)
        assert conn.status == 403
        assert Jason.decode!(conn.resp_body)["error"] == "forbidden"
      end

      for ip <- [
            {192, 168, 1, 50},
            {10, 0, 0, 7},
            {172, 16, 4, 4},
            {169, 254, 10, 10},
            {0, 0, 0, 0, 0, 0xFFFF, 0xC0A8, 0x0132},
            {0xFE80, 0, 0, 0, 0, 0, 0, 1},
            {0xFD00, 0, 0, 0, 0, 0, 0, 1}
          ] do
        assert from(ip, "/api/boards/v1/link", auth).status == 200
      end
    end

    test "refused codes are counted against the address the connection came from, whatever a header says" do
      # Even on a copy somebody configured as if it sat behind a proxy.
      previous = Application.get_env(:pairings_engine, :trusted_proxy_hops, 0)
      Application.put_env(:pairings_engine, :trusted_proxy_hops, 1)
      on_exit(fn -> Application.put_env(:pairings_engine, :trusted_proxy_hops, previous) end)

      max = RateLimit.config(:board_link_auth).max

      wrong = fn ip, forwarded ->
        from(ip, "/api/boards/v1/link", [
          {"authorization", "Bearer oplt_wrong_wrong_wrong_wrong"},
          {"x-forwarded-for", forwarded},
          {"forwarded", "for=#{forwarded}"},
          {"x-real-ip", forwarded}
        ])
      end

      # One machine, pretending to be a different one each time.
      for n <- 1..max do
        assert wrong.({192, 168, 1, 66}, "203.0.113.#{n}").status == 401
      end

      assert RateLimit.count(:board_link_auth, "192.168.1.66") == max
      assert RateLimit.count(:board_link_auth, "203.0.113.1") == 0

      limited = wrong.({192, 168, 1, 66}, "203.0.113.200")
      assert limited.status == 429
      assert Jason.decode!(limited.resp_body)["error"] == "rate_limited"

      # Its neighbour is not the one who guessed.
      assert wrong.({192, 168, 1, 67}, "192.168.1.66").status == 401
    end

    test "a good code is counted against itself, and not turned away for a neighbour's guesses",
         %{
           scope: scope,
           tournament: t
         } do
      {link, secret, _status} = lan_code!(scope, t)
      max = RateLimit.config(:board_link_auth).max

      for _ <- 1..(max + 1) do
        from({192, 168, 1, 66}, "/api/boards/v1/link", [
          {"authorization", "Bearer oplt_wrong_wrong_wrong"}
        ])
      end

      # The box shares that address with whoever was guessing.
      good =
        from({192, 168, 1, 66}, "/api/boards/v1/link", [{"authorization", "Bearer " <> secret}])

      assert good.status == 200
      assert RateLimit.count(:board_link, Integer.to_string(link.id)) >= 1
    end
  end

  describe "the routes" do
    test "the network listener's router has the board link's routes, the same ones, and no others" do
      # The grant of the account flow is the one board route the listener
      # does not have, on purpose: account codes are not for the network.
      board = fn router ->
        for route <- Phoenix.Router.routes(router),
            String.starts_with?(route.path, "/api/boards/v1"),
            route.path != "/api/boards/v1/grant",
            do: {route.verb, route.path, route.plug, route.plug_opts}
      end

      refute Enum.any?(Phoenix.Router.routes(BoardLan.Router), &(&1.path =~ "grant"))

      assert Enum.any?(
               Phoenix.Router.routes(PairingsEngineWeb.Router),
               &(&1.path == "/api/boards/v1/grant")
             )

      everything = Phoenix.Router.routes(BoardLan.Router)

      assert length(everything) == 4
      assert Enum.sort(board.(BoardLan.Router)) == Enum.sort(board.(PairingsEngineWeb.Router))
      assert length(board.(BoardLan.Router)) == length(everything)

      for route <- everything do
        method = route.verb |> to_string() |> String.upcase()
        path_info = route.path |> String.replace(":id", "7") |> String.split("/", trim: true)
        assert BoardLan.Plug.board_route?(method, path_info), "#{method} #{route.path}"
      end

      refute BoardLan.Plug.board_route?("GET", [])
      refute BoardLan.Plug.board_route?("GET", ["live", "websocket"])
    end

    test "the plug has no session and signs nobody in" do
      desktop()

      conn = Plug.Test.conn(:get, "/") |> BoardLan.Plug.call([])
      assert conn.status == 404
      assert conn.resp_cookies == %{}
      assert Plug.Conn.get_resp_header(conn, "set-cookie") == []
      refute Map.has_key?(conn.private, :plug_session)
      refute Map.has_key?(conn.assigns, :current_scope)
    end
  end

  describe "an address that changed" do
    setup :desktop

    test "is noticed, said with both addresses, and not followed without being asked", %{
      conn: conn,
      port: port,
      scope: scope,
      tournament: t
    } do
      {link, secret, %{state: :listening}} = lan_code!(scope, t)

      # The network hands this PC another address.
      Application.put_env(:pairings_engine, :board_lan_addresses, ["127.0.0.2"])

      status = BoardLan.status()
      assert %{state: :address_gone, address: "127.0.0.1", addresses: ["127.0.0.2"]} = status
      assert status.base_url == nil
      # Not listening on the old one, and not on the new one either.
      assert listeners() == 0
      assert {:error, _} = ask(port, "/api/boards/v1/link", secret: secret, host: "127.0.0.2")

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/boards")
      notice = lv |> element("#boards-lan-state") |> render()
      assert notice =~ "127.0.0.1"
      assert notice =~ "127.0.0.2"
      assert has_element?(lv, "#boards-lan-state[role=alert]")
      assert has_element?(lv, "#board-link-stranded-#{link.id}")
      refute has_element?(lv, "#tournament-codes-new-lan")

      # The arbiter picks the new one.
      lv
      |> form("#boards-lan-form", %{"lan" => %{"address" => "127.0.0.2", "port" => "#{port}"}})
      |> render_submit()

      assert %{state: :listening, address: "127.0.0.2"} = BoardLan.status()

      assert {:ok, %{status: 200}} =
               ask(port, "/api/boards/v1/link", secret: secret, host: "127.0.0.2")

      # The old code still says the old address, and the page says so.
      stranded = lv |> element("#board-link-stranded-#{link.id}") |> render()
      assert stranded =~ "http://127.0.0.1:#{port}"
      assert stranded =~ "http://127.0.0.2:#{port}"

      lv |> element("#tournament-codes-new-lan") |> render_click()

      assert lv |> element("#tournament-codes-code") |> render() =~
               "http://127.0.0.2:#{port}/api/boards/v1#oplt_"
    end

    test "is noticed when the program starts", %{scope: scope, tournament: t} do
      lan_code!(scope, t)
      Application.put_env(:pairings_engine, :board_lan_addresses, ["127.0.0.2"])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          :ok = Supervisor.terminate_child(PairingsEngine.Supervisor, BoardLan)
          {:ok, _pid} = Supervisor.restart_child(PairingsEngine.Supervisor, BoardLan)
          _ = :sys.get_state(BoardLan)
        end)

      assert log =~ "no longer has the address 127.0.0.1"
      assert log =~ "127.0.0.2"
      assert listeners() == 0
    end

    test "a PC with no network at all says that", %{conn: conn, tournament: t} do
      Application.put_env(:pairings_engine, :board_lan_addresses, [])
      Meta.delete("board_lan_address")

      assert %{state: :no_address, base_url: nil} = BoardLan.status()
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/boards")
      assert has_element?(lv, "#boards-lan[data-state=no_address]")
      refute has_element?(lv, "#boards-lan-form")
    end
  end

  describe "Connections on a desktop copy" do
    setup :desktop

    test "says where it stands and can switch it off", %{conn: conn, scope: scope, tournament: t} do
      {:ok, lv, _html} = live(conn, ~p"/fide")
      assert has_element?(lv, "#connections-board-lan-state", "closed until a code")

      lan_code!(scope, t)
      {:ok, lv, _html} = live(conn, ~p"/fide")

      assert has_element?(
               lv,
               "#connections-board-lan-state",
               "answering boxes at http://127.0.0.1:"
             )

      assert listeners() == 1

      lv |> element("#connections-board-lan-off") |> render_click()
      assert has_element?(lv, "#connections-board-lan-state", "Off")
      refute has_element?(lv, "#connections-board-lan-off")
      assert listeners() == 0
      assert %{enabled?: false} = BoardLan.status()
    end
  end

  describe "Settings, Live boards on a desktop copy" do
    test "the switch, the warning, the two kinds of code and where each leads", %{
      conn: conn,
      tournament: t
    } do
      previous = Application.get_env(:pairings_engine, :local_mode)
      Application.put_env(:pairings_engine, :local_mode, true)
      Application.put_env(:pairings_engine, :board_lan_addresses, ["127.0.0.1"])
      port = spare_port()
      Meta.put("board_lan_port", Integer.to_string(port))

      on_exit(fn ->
        BoardLan.switch(false)
        Application.delete_env(:pairings_engine, :board_lan_addresses)

        case previous do
          nil -> Application.delete_env(:pairings_engine, :local_mode)
          value -> Application.put_env(:pairings_engine, :local_mode, value)
        end
      end)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/boards")

      # Off, and said so; one kind of code, for this computer.
      assert has_element?(lv, "#boards-lan[data-state=off]")
      assert has_element?(lv, "#boards-lan-toggle[aria-checked=false]")
      assert has_element?(lv, "#boards-lan-warning", "plain http")
      refute has_element?(lv, "#boards-lan-state")
      refute has_element?(lv, "#tournament-codes-new-lan")
      assert has_element?(lv, "#boards-address", "cannot reach it until you switch on")
      assert listeners() == 0

      lv |> element("#tournament-codes-new") |> render_click()
      here = lv |> element("#tournament-codes-code") |> render()
      assert here =~ PairingsEngineWeb.BoardLinkAddress.base_url() <> "/api/boards/v1#oplt_"
      assert PairingsEngineWeb.BoardLinkAddress.base_url() =~ "http://127.0.0.1:"
      assert has_element?(lv, "#tournament-codes-where", "on this computer")
      [%Link{reach: nil}] = Repo.all(Link)
      # A code for this computer opens no port.
      assert listeners() == 0

      # On.
      lv |> element("#boards-lan-toggle") |> render_click()
      assert has_element?(lv, "#boards-lan-toggle[aria-checked=true]")
      assert has_element?(lv, "#boards-lan[data-state=idle]")
      assert has_element?(lv, "#boards-lan-state[role=status]", "http://127.0.0.1:#{port}")
      assert has_element?(lv, "#boards-lan-firewall", "Windows will ask")
      assert has_element?(lv, "#boards-lan-address option[selected]", "127.0.0.1")
      assert Meta.get("board_lan_enabled") == "1"

      lv |> element("#tournament-codes-new-lan") |> render_click()
      there = lv |> element("#tournament-codes-code") |> render()
      assert there =~ "http://127.0.0.1:#{port}/api/boards/v1#oplt_"
      where = lv |> element("#tournament-codes-where") |> render()
      assert where =~ "on the network"
      assert where =~ "http://127.0.0.1:#{port}"

      link = Repo.get_by!(Link, reach: "lan")
      assert has_element?(lv, "#board-link-reach-#{link.id}", "Network")
      assert has_element?(lv, "#board-link-expiry-#{link.id}", "http://127.0.0.1:#{port}")
      refute has_element?(lv, "#board-link-stranded-#{link.id}")
      assert has_element?(lv, "#boards-lan[data-state=listening]")

      [_, secret] = Regex.run(~r/#(oplt_[A-Za-z0-9_-]+)/, there)
      assert {:ok, %{status: 200}} = ask(port, "/api/boards/v1/link", secret: secret)

      # In the trail, with the address and without the secret.
      actions = t.id |> Audit.list_for_tournament(limit: 50) |> Map.new(&{&1.action, &1.details})

      assert %{"enabled" => true, "address" => "127.0.0.1", "port" => ^port} =
               actions["boards.lan_switched"]

      refute inspect(Audit.list_for_tournament(t.id, limit: 50)) =~ secret

      # Off: the box is cut off at once, the code is kept and says why it is idle.
      lv |> element("#boards-lan-toggle") |> render_click()
      assert has_element?(lv, "#boards-lan[data-state=off]")
      assert listeners() == 0
      assert {:error, _} = ask(port, "/api/boards/v1/link", secret: secret)
      assert has_element?(lv, "#board-link-stranded-#{link.id}", "switch above is off")
    end
  end
end
