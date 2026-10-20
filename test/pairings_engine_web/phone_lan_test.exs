defmodule PairingsEngineWeb.PhoneLanTest do
  @moduledoc """
  "Let phones on this network connect" (`PairingsEngineWeb.PhoneLan`): a
  desktop copy's listener for Manubrium, which answers the phone pages and
  nothing else.

  Like the board link's (`board_lan_test.exs`), the listener is started for
  real on a spare port of 127.0.0.1 and asked over HTTP: "only the phone
  pages answer there" is a claim about a socket. The machine's network
  addresses are handed in (`:board_lan_addresses`).
  """
  use PairingsEngineWeb.ConnCase, async: false

  import PairingsEngine.BoardLinkFixtures

  alias PairingsEngine.{Meta, Mobile}
  alias PairingsEngineWeb.PhoneLan

  @supervisor PairingsEngineWeb.PhoneLan.Supervisor

  setup :register_and_log_in_user

  setup %{scope: scope} do
    paired_tournament(scope)
  end

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
      PhoneLan.switch(false)
      Application.delete_env(:pairings_engine, :board_lan_addresses)

      case previous do
        nil -> Application.delete_env(:pairings_engine, :local_mode)
        value -> Application.put_env(:pairings_engine, :local_mode, value)
      end
    end)

    port = spare_port()
    {:ok, _} = PhoneLan.switch(true)
    {:ok, status} = PhoneLan.choose("127.0.0.1", port)
    %{port: port, status: status}
  end

  # A code, and the look that opens the listener for it.
  defp code!(tournament) do
    {:ok, enrollment} = Mobile.create_enrollment(tournament.id, level: "deputy")
    {enrollment, PhoneLan.status()}
  end

  defp ask(port, path, opts \\ []) do
    Req.request(
      [
        url: "http://127.0.0.1:#{port}#{path}",
        method: :get,
        retry: false,
        redirect: false,
        receive_timeout: 5_000,
        connect_options: [timeout: 700]
      ] ++ opts
    )
  end

  defp listeners, do: DynamicSupervisor.count_children(@supervisor).active

  defp session_cookie(response) do
    response
    |> Req.Response.get_header("set-cookie")
    |> Enum.find(&String.starts_with?(&1, "_pairings_engine_key="))
  end

  describe "a hosted server" do
    test "has no switch and no listener, and its plug answers nothing", %{tournament: t} do
      refute PhoneLan.available?()
      assert PhoneLan.switch(true) == {:error, :unavailable}
      assert PhoneLan.choose("127.0.0.1", 4748) == {:error, :unavailable}
      assert %{available?: false, base_url: nil} = PhoneLan.status()
      assert Meta.get(Mobile.lan_key()) == nil
      assert listeners() == 0

      conn = Plug.Test.conn(:get, "/m") |> PhoneLan.Plug.call([])
      assert conn.status == 404

      # A hosted server makes phone codes as it always did.
      assert {:ok, _enrollment} = Mobile.create_enrollment(t.id)
    end
  end

  describe "a desktop copy with the switch off" do
    test "makes no phone codes: they would lead nowhere", %{tournament: t} do
      previous = Application.get_env(:pairings_engine, :local_mode)
      Application.put_env(:pairings_engine, :local_mode, true)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:pairings_engine, :local_mode)
          value -> Application.put_env(:pairings_engine, :local_mode, value)
        end
      end)

      Meta.delete(Mobile.lan_key())
      assert Mobile.create_enrollment(t.id) == {:error, :local_mode}
      assert listeners() == 0
    end
  end

  describe "the switch" do
    setup :desktop

    test "on is not yet an open port: it waits for the first code", %{port: port, status: status} do
      assert %{enabled?: true, state: :idle, address: "127.0.0.1", port: ^port} = status
      assert status.base_url == "http://127.0.0.1:#{port}"
      assert listeners() == 0
      assert {:error, %Req.TransportError{}} = ask(port, "/m")
    end

    test "opens with the first code and closes with the last", %{port: port, tournament: t} do
      {enrollment, status} = code!(t)
      assert status.state == :listening
      assert listeners() == 1
      assert {:ok, %{status: 200}} = ask(port, "/m")

      {:ok, _} = Mobile.revoke(enrollment)
      assert %{state: :idle} = PhoneLan.status()
      assert listeners() == 0
      assert {:error, %Req.TransportError{}} = ask(port, "/m")
    end

    test "refuses its own ports", %{port: port} do
      own = PairingsEngineWeb.Endpoint.config(:http)[:port]
      if own, do: assert(PhoneLan.choose("127.0.0.1", own) == {:error, :bad_port})
      assert PhoneLan.choose("127.0.0.1", 80) == {:error, :bad_port}
      assert PhoneLan.choose("10.9.8.7", port) == {:error, :not_an_address}
    end
  end

  describe "what answers there" do
    setup :desktop

    test "the phone pages, and a 404 for the desk", %{port: port, tournament: t} do
      {enrollment, _status} = code!(t)

      assert {:ok, %{status: 200, body: body}} = ask(port, "/m/e/#{enrollment.token}")
      assert body =~ "enroll-confirm-form"

      assert {:ok, %{status: 302} = root} = ask(port, "/")
      assert Req.Response.get_header(root, "location") == ["/m"]

      for path <- [
            "/t/#{t.id}/players",
            "/t/#{t.id}/pairings",
            "/users/settings",
            "/users/log-in",
            "/m/connect",
            "/api/boards/v1/link",
            "/admin",
            "/t/#{t.id}/incidents/1/photo"
          ] do
        assert {:ok, %{status: 404}} = ask(port, path), "#{path} answered on the phones' port"
      end
    end

    test "a phone enrols over it, and its session cookie is not marked Secure", %{
      port: port,
      tournament: t
    } do
      {enrollment, _status} = code!(t)

      {:ok, page} = ask(port, "/m/e/#{enrollment.token}")
      cookie = session_cookie(page)
      assert cookie
      refute cookie =~ ~r/;\s*secure/i

      [_, csrf] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, page.body)
      cookie_pair = cookie |> String.split(";", parts: 2) |> hd()

      {:ok, claimed} =
        ask(port, "/m/e/#{enrollment.token}",
          method: :post,
          form: [_csrf_token: csrf],
          headers: [{"cookie", cookie_pair}]
        )

      assert claimed.status == 302
      assert Req.Response.get_header(claimed, "location") == ["/m/results"]
      refute session_cookie(claimed) =~ ~r/;\s*secure/i
      assert %DateTime{} = PairingsEngine.Repo.get!(Mobile.Enrollment, enrollment.id).claimed_at
    end

    test "a caller from a public address is turned away" do
      conn =
        Plug.Test.conn(:get, "/m")
        |> Map.put(:remote_ip, {8, 8, 8, 8})
        |> PhoneLan.Plug.call([])

      assert conn.status == 403
    end
  end

  describe "the helpers config asks" do
    setup :desktop

    test "lan_request?/1 is true for this listener's requests only" do
      assert PhoneLan.lan_request?(
               Plug.Conn.put_private(Plug.Test.conn(:get, "/m"), :phone_lan, true)
             )

      refute PhoneLan.lan_request?(Plug.Test.conn(:get, "/m"))
    end

    test "origin_allowed?/1 knows the endpoint's host, and the listener while it listens", %{
      port: port,
      tournament: t
    } do
      own = PairingsEngineWeb.Endpoint.config(:url)[:host] || "localhost"
      assert PhoneLan.origin_allowed?(URI.parse("http://#{own}:4000"))
      refute PhoneLan.origin_allowed?(URI.parse("http://192.168.1.20:#{port}"))
      refute PhoneLan.origin_allowed?(URI.parse("http://evil.example"))

      {_enrollment, %{state: :listening}} = code!(t)
      assert PhoneLan.origin_allowed?(URI.parse("http://127.0.0.1:#{port}"))
    end
  end
end
