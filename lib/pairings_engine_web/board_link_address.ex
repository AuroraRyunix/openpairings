defmodule PairingsEngineWeb.BoardLinkAddress do
  @moduledoc """
  The address a hall box is told to call (`PairingsEngine.BoardLink`), and
  the connect code built from it.

  ## A code must not lie about where it leads

  Hosted, the address is the endpoint's own public URL.

  A desktop copy's own listener answers on loopback and nowhere else - that
  pin is what makes having no login safe (`config/runtime.exs`), and nothing
  here moves it. A code for a box program **on the same PC** says exactly
  that: `http://127.0.0.1:<port>`. Not `localhost`, which a machine may
  resolve to `::1`, where nothing listens.

  A box **on another machine** needs the PC's network address, and gets it
  only where something answers there: when the arbiter has switched on
  "Let boards on this network connect" (`PairingsEngineWeb.BoardLan`), which
  opens a second listener for the board link alone. Then, and only then, a
  second form of code exists, with `http://<this PC's address>:<its port>`.
  Without the switch there is no such code - a code with the PC's address
  and nothing listening on it would look right, scan right and never
  connect.

  So a code is made for one form, and the page says which next to it.

  ## The code

      <address>/api/boards/v1#<secret>

  One line of text, the same in the QR code. The secret rides in the
  fragment on purpose: pasted into a browser or a chat window by mistake,
  the part after `#` is not sent to anybody.
  """

  alias PairingsEngine.Authz
  alias PairingsEngineWeb.Endpoint

  @path "/api/boards/v1"

  @doc "The API's path under the server address."
  def path, do: @path

  @doc """
  The address of this program's own listener: the public one on a server,
  `http://127.0.0.1:<port>` on a desktop copy.
  """
  def base_url do
    if Authz.local_mode?() do
      "http://127.0.0.1:#{local_port()}"
    else
      Endpoint.url()
    end
  end

  @doc "Whether that address works from another machine."
  def reachable_from_other_machines?, do: not Authz.local_mode?()

  @doc """
  The connect code for `secret`: what is shown as text and drawn as a QR
  code. With no `base` it leads to `base_url/0`; a code for a box on the
  network is given the network listener's address
  (`PairingsEngineWeb.BoardLan.status/0`, `:base_url`).
  """
  def connect_code(secret, base \\ nil) when is_binary(secret),
    do: String.trim_trailing(base || base_url(), "/") <> @path <> "#" <> secret

  # The port the listener is on, not the one in the URL config: they are the
  # same in local mode today, and the listener is the one that is true.
  defp local_port do
    case Endpoint.config(:http) do
      http when is_list(http) -> Keyword.get(http, :port) || url_port()
      _other -> url_port()
    end
  end

  defp url_port, do: URI.parse(Endpoint.url()).port || 4000
end
