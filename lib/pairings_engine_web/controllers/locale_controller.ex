defmodule PairingsEngineWeb.LocaleController do
  @moduledoc """
  Switching language.

  A plain controller rather than a LiveView event, because the choice lives
  in the SESSION and a LiveView cannot write one - it holds a socket, not a
  conn. This is the same reason the theme switch is client-side and this is
  not: a theme is a browser preference, a language has to be known by the
  server before it renders anything.

  Returns the visitor to where they were via the `redirect_to` parameter,
  validated as a local path. An open redirect here would be a genuine one:
  the link is presented as "change language" and would send people to
  another site instead.
  """
  use PairingsEngineWeb, :controller

  alias PairingsEngineWeb.Locale

  def update(conn, %{"locale" => locale} = params) do
    conn =
      if Locale.known?(locale) do
        put_session(conn, Locale.session_key(), locale)
      else
        conn
      end

    redirect(conn, to: safe_path(params["redirect_to"]))
  end

  # Only same-origin paths. A value starting "//" is protocol-relative and
  # goes to another host despite looking local, which is exactly the case a
  # naive `String.starts_with?("/")` check waves through.
  defp safe_path("/" <> rest = path) when not is_nil(path) do
    if String.starts_with?(rest, "/"), do: "/", else: path
  end

  defp safe_path(_other), do: "/"
end
