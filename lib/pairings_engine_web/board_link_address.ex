defmodule PairingsEngineWeb.BoardLinkAddress do
  @moduledoc """
  The address a hall box is told to call (`PairingsEngine.BoardLink`), and
  the connect code built from it.

  ## A code must not lie about where it leads

  Hosted, the address is the endpoint's own public URL.

  A desktop copy answers on loopback and nowhere else - that pin is what
  makes having no login safe (`config/runtime.exs`), and nothing here moves
  it. So the only box that can reach a desktop copy is one on the same PC,
  and the code says exactly that: `http://127.0.0.1:<port>`. Not
  `localhost`, which a machine may resolve to `::1`, where nothing listens.
  Not the PC's LAN address, which would be a code that looks right, scans
  right and never connects.

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

  @doc "The server address a box on the far side of a code would use."
  def base_url do
    if Authz.local_mode?() do
      "http://127.0.0.1:#{local_port()}"
    else
      Endpoint.url()
    end
  end

  @doc "Whether that address works from another machine."
  def reachable_from_other_machines?, do: not Authz.local_mode?()

  @doc "The connect code for `secret`: what is shown as text and drawn as a QR code."
  def connect_code(secret) when is_binary(secret), do: base_url() <> @path <> "#" <> secret

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
