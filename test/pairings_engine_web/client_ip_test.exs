defmodule PairingsEngineWeb.ClientIpTest do
  use PairingsEngineWeb.ConnCase, async: true

  alias PairingsEngineWeb.ClientIp

  setup do
    original = Application.get_env(:pairings_engine, :trusted_proxy_hops, 0)
    on_exit(fn -> Application.put_env(:pairings_engine, :trusted_proxy_hops, original) end)
    :ok
  end

  defp hops(n), do: Application.put_env(:pairings_engine, :trusted_proxy_hops, n)

  defp conn_from(remote_ip, forwarded_for) do
    conn = %{Phoenix.ConnTest.build_conn() | remote_ip: remote_ip}

    Enum.reduce(List.wrap(forwarded_for), conn, fn value, acc ->
      Plug.Conn.put_req_header(acc, "x-forwarded-for", value)
    end)
  end

  describe "with no trusted proxy (the default)" do
    test "uses the peer address and ignores a forged header" do
      hops(0)

      assert ClientIp.get(conn_from({203, 0, 113, 7}, "1.2.3.4")) == "203.0.113.7"
    end
  end

  describe "behind one proxy" do
    test "takes the address the proxy appended, not the client-supplied prefix" do
      hops(1)

      # The proxy appends the peer it saw; everything left of that is whatever
      # the client chose to send, and must not win.
      assert ClientIp.get(conn_from({10, 0, 0, 1}, "1.2.3.4, 198.51.100.9")) == "198.51.100.9"
    end

    test "a lone entry is the proxy's own observation" do
      hops(1)

      assert ClientIp.get(conn_from({10, 0, 0, 1}, "198.51.100.9")) == "198.51.100.9"
    end

    test "falls back to the peer when the header is absent" do
      hops(1)

      assert ClientIp.get(conn_from({10, 0, 0, 1}, [])) == "10.0.0.1"
    end
  end

  describe "behind two chained proxies" do
    test "counts hops from the right" do
      hops(2)

      assert ClientIp.get(conn_from({10, 0, 0, 1}, "1.2.3.4, 198.51.100.9, 10.0.0.2")) ==
               "198.51.100.9"
    end

    test "a header shorter than the hop count falls back to the peer rather than trusting it" do
      hops(2)

      assert ClientIp.get(conn_from({10, 0, 0, 1}, "1.2.3.4")) == "10.0.0.1"
    end
  end

  test "handles a header split across several lines and stray whitespace" do
    hops(1)

    assert ClientIp.get(conn_from({10, 0, 0, 1}, ["1.2.3.4 ", " 198.51.100.9"])) == "198.51.100.9"
  end
end
