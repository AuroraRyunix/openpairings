defmodule PairingsEngineWeb.Plugs.CanonicalHost do
  @moduledoc """
  Moves requests that arrive on an old hostname to the canonical one.

  Off unless `PHX_REDIRECT_HOSTS` names at least one host (see
  `config/runtime.exs`), so deploying this changes nothing until somebody
  decides it should: a request on any other host, including loopback and the
  box's own health checks, passes straight through.

  Only `GET` and `HEAD` are redirected. A `301` makes a client re-send as a
  `GET`, which would silently turn a form post or an API call into a page
  view and lose its body; those keep being answered where they land, and
  whoever sends them moves when they are ready.

  The policy is read from `config :pairings_engine, :host_policy` on every
  request (a keyword list: `:canonical`, `:redirect_hosts`), so a test can
  set it without recompiling.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{method: method} = conn, _opts) when method in ["GET", "HEAD"] do
    policy = Application.get_env(:pairings_engine, :host_policy, [])
    canonical = policy[:canonical]
    host = String.downcase(conn.host || "")

    if is_binary(canonical) and canonical != host and host in List.wrap(policy[:redirect_hosts]) do
      query = if conn.query_string == "", do: "", else: "?" <> conn.query_string

      conn
      |> put_resp_header("location", "https://" <> canonical <> conn.request_path <> query)
      |> send_resp(301, "")
      |> halt()
    else
      conn
    end
  end

  def call(conn, _opts), do: conn
end
