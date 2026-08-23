defmodule PairingsEngineWeb.Plugs.Locale do
  @moduledoc """
  Sets the request's locale and writes the resolved value back into the
  session.

  Writing it back matters: without it, a visitor whose language came from
  `accept-language` would have nothing in the session, so the LiveView
  mounting a moment later would have to re-derive it from a header it cannot
  see. Resolving once here and storing the answer means the dead render and
  the live one always agree - and disagreeing is the visible bug, a page
  that renders in one language and then swaps to another as it connects.
  """
  import Plug.Conn

  alias PairingsEngineWeb.Locale

  def init(opts), do: opts

  def call(conn, _opts) do
    locale =
      Locale.resolve(
        get_session(conn),
        conn |> get_req_header("accept-language") |> List.first()
      )

    Gettext.put_locale(PairingsEngineWeb.Gettext, locale)

    conn
    |> put_session(Locale.session_key(), locale)
    |> assign(:locale, locale)
  end
end
