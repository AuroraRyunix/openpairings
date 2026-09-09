defmodule PairingsEngineWeb.Plugs.RequestLogging do
  @moduledoc """
  Keeps bearer tokens out of the request log.

  `Plug.Telemetry` is what makes Phoenix log `GET <request_path>` at `:info`
  for every request, and five of this app's routes carry a secret **in the
  path** rather than in a header, a cookie or a body: the magic-link log-in,
  the confirm-email link, a collaborator invite, a public-tools download and
  a phone enrolment. For all five, holding the URL *is* the authentication -
  so a log line naming one is the credential itself, and the log-in token
  stays live for another fifteen minutes after it lands there. A log is
  shipped, tailed over somebody's shoulder and kept for months; a session
  store is none of those things.

  Going quiet on those five routes would trade a leak for a blind spot, so
  the request is still logged and only the secret segment is not:
  `GET /users/log-in/[FILTERED]`. `log_level/1` suppresses the line Phoenix
  would otherwise write for the same request; every other request is
  untouched and logged exactly as before.

  Wired up in `PairingsEngineWeb.Endpoint`, immediately before the
  `Plug.Telemetry` whose line it replaces, so the ordering of the log is
  unchanged too. Both lines carry the same `request_id` (`Plug.RequestId`
  runs first), which is what ties this one to the `Sent 200 in 3ms` that
  Phoenix still writes at the end.
  """
  require Logger

  @filtered "[FILTERED]"

  # `PairingsEngineWeb.ToolsController`'s own list. Naming them means the log
  # can say which form was downloaded without echoing a path segment a
  # visitor wrote - a decoded segment can contain a newline, and a log line
  # an outsider can add lines to is its own problem.
  @tools_forms ~w(it3 fa1 ia1)

  def init(opts), do: opts

  def call(conn, _opts) do
    case redacted_path(conn.path_info) do
      nil -> conn
      path -> log_request(conn, path)
    end
  end

  @doc """
  The level Phoenix's own endpoint logging runs at for `conn`.

  Wired up as `log: {__MODULE__, :log_level, []}` on `Plug.Telemetry`, which
  consults it for both of that plug's events: the start event, which prints
  the request path, and the stop event, which prints only the status and the
  duration. Only the first can carry a token, so only the first is
  suppressed - `conn.status` is still `nil` on the way in and set by the time
  the response is sent, which is what tells the two apart.

  `:info` is Phoenix's own default for both, so every path this does not
  redact logs exactly as it did before this plug existed.
  """
  def log_level(%Plug.Conn{status: nil} = conn) do
    if redacted_path(conn.path_info), do: false, else: :info
  end

  def log_level(%Plug.Conn{}), do: :info

  defp log_request(conn, path) do
    Logger.info([conn.method, ?\s, path])
    conn
  end

  # Every route whose path carries a secret, matched on `path_info` (decoded
  # and correctly delimited) but rendered from literals, so nothing a visitor
  # typed reaches the log. Keep this list next to the router: a new
  # token-in-path route that is not here is logged in full.
  defp redacted_path(["users", "log-in", _token]), do: "/users/log-in/#{@filtered}"

  defp redacted_path(["users", "settings", "confirm-email", _token]),
    do: "/users/settings/confirm-email/#{@filtered}"

  defp redacted_path(["invites", _token]), do: "/invites/#{@filtered}"

  defp redacted_path(["tools", "download", _token, form]) when form in @tools_forms,
    do: "/tools/download/#{@filtered}/#{form}"

  defp redacted_path(["tools", "download", _token | _rest]), do: "/tools/download/#{@filtered}"

  defp redacted_path(["m", "e", _token]), do: "/m/e/#{@filtered}"

  defp redacted_path(_path_info), do: nil
end
