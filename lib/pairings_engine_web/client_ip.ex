defmodule PairingsEngineWeb.ClientIp do
  @moduledoc """
  The address to attribute a request to, for rate limiting.

  `conn.remote_ip` is the peer socket address, which behind a reverse proxy
  is the *proxy* - every visitor then shares one bucket, so a limiter keyed
  on it either throttles the whole venue at once or, worse, lets one attacker
  lock everybody out. `X-Forwarded-For` fixes that, but only if it is read
  correctly: any part of it the client sent is forged, and the only entry
  that can be trusted is the one your own proxy appended.

  So this is configured in hops, not in headers. `:trusted_proxy_hops` says
  how many proxies sit in front of the app (`TRUSTED_PROXY_HOPS`, see
  `config/runtime.exs`):

    * `0` (default) - no proxy, or an untrusted one: use `conn.remote_ip`
      and ignore the header entirely. A forged header must never win when
      nothing was promised about the deployment.
    * `1` - one reverse proxy (nginx/Caddy/Traefik/a cloud LB). The client is
      the LAST entry of `X-Forwarded-For`, because each proxy appends the
      address it received the request from.
    * `n` - n chained proxies: the nth entry counted from the right.

  Falling back to `conn.remote_ip` whenever the header is missing or too
  short means a misconfigured hop count degrades to "throttle the proxy",
  never to "trust whatever the client typed".
  """

  @doc "The client address for `conn`, as a string, per the configured hop count."
  @spec get(Plug.Conn.t()) :: String.t()
  def get(%Plug.Conn{} = conn) do
    resolve(address(conn.remote_ip), Plug.Conn.get_req_header(conn, "x-forwarded-for"))
  end

  @doc """
  The client address for a LiveView, from the socket's connect info (see the
  endpoint's `:peer_data` / `:x_headers`).

  **Call this in `mount/3` and keep the result in assigns.** Connect info is
  only readable while mounting; `handle_event/3` raises if you reach for it
  there.

  Returns `nil` for the first, static render, which has no socket peer -
  mount runs again once the browser connects. Treat `nil` as "unknown"
  rather than falling back to a key many visitors would share.
  """
  @spec from_socket(Phoenix.LiveView.Socket.t()) :: String.t() | nil
  def from_socket(socket) do
    case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
      %{address: peer} ->
        forwarded =
          socket
          |> Phoenix.LiveView.get_connect_info(:x_headers)
          |> List.wrap()
          |> Enum.filter(fn {name, _value} -> name == "x-forwarded-for" end)
          |> Enum.map(fn {_name, value} -> value end)

        resolve(address(peer), forwarded)

      _ ->
        nil
    end
  end

  defp resolve(peer, forwarded_values) do
    case hops() do
      hops when hops > 0 -> forwarded_for(forwarded_values, hops) || peer
      _ -> peer
    end
  end

  defp hops, do: Application.get_env(:pairings_engine, :trusted_proxy_hops, 0)

  defp address(ip), do: ip |> :inet.ntoa() |> to_string()

  defp forwarded_for(values, hops) do
    entries =
      values
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    # `hops` entries were appended by our own proxies; the first of those (the
    # one furthest right minus the hops above it) is the address the outermost
    # trusted proxy actually saw. Anything to its left is client-supplied.
    #
    # The index must be checked, not just handed to `Enum.at/2`: a header
    # with fewer entries than the configured hop count gives a negative
    # index, which wraps around and hands back a client-supplied entry -
    # precisely the value this module exists to distrust.
    case length(entries) - hops do
      index when index >= 0 -> Enum.at(entries, index)
      _ -> nil
    end
  end
end
