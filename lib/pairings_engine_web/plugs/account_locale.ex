defmodule PairingsEngineWeb.Plugs.AccountLocale do
  @moduledoc """
  Makes a language stored on the account win over the session's.

  `PairingsEngineWeb.Plugs.Locale` runs before anybody is signed in - it has
  to, the log-in page itself is translated - so it can only go by the
  session and the browser. This runs after
  `PairingsEngineWeb.UserAuth.fetch_current_scope_for_user/2` and, when the
  signed-in account has a language of its own (`users.locale`, chosen on
  the account page or with the top-bar picker), puts that one in the
  session and in effect for this request.

  That is what makes the language follow the person: sign in on a borrowed
  laptop whose browser asks for English and the pages come up in
  Nederlands anyway, and a switch made on the phone reaches the desktop on
  its next page load.

  An account with no stored language (`nil`, the default) changes nothing,
  so this is inert for everyone who never chose.
  """
  import Plug.Conn

  alias PairingsEngineWeb.Locale

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:current_scope] do
      %{user: %{locale: locale}} when is_binary(locale) ->
        if Locale.known?(locale) and locale != conn.assigns[:locale] do
          Gettext.put_locale(PairingsEngineWeb.Gettext, locale)

          conn
          |> put_session(Locale.session_key(), locale)
          |> assign(:locale, locale)
        else
          conn
        end

      _ ->
        conn
    end
  end
end
