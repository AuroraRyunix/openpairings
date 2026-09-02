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

  # Only same-origin paths, and only ones Phoenix will actually accept.
  #
  # Two separate hazards, and this used to catch one of them:
  #
  #   * **Protocol-relative.** A value starting `//` goes to another host
  #     despite looking local, which a naive `starts_with?("/")` waves
  #     through. Caught since this function was written.
  #
  #   * **Characters `redirect/2` refuses.** Phoenix rejects any local URL
  #     containing a backslash, a tab, or their encoded forms
  #     (`@invalid_local_url_chars` in `Phoenix.Controller`) - it raises
  #     rather than redirecting. So `?redirect_to=/%5Cevil.com` reached
  #     `redirect(conn, to: "\\evil.com")` and turned a crafted URL into a
  #     500. Not an open redirect - Phoenix stopped that - but an
  #     unauthenticated visitor could produce a server error at will, and a
  #     language switch is not a place to find one.
  #
  # Checked here rather than trusted to the framework because this value
  # comes from a query string on a public route, and the right answer to
  # "somebody sent nonsense" is the home page, not a stack trace.
  #
  # An ALLOWLIST, not the denylist this used to be. The denylist named the
  # characters Phoenix refuses and missed the ones `put_resp_header/3`
  # refuses: a decoded CR or LF walked straight through it into
  # `Plug.Conn.InvalidHeaderError`, so `?redirect_to=%0A` was a 500 anyone
  # could ask for. Naming what a URL path may contain instead means the
  # next character somebody finds objectionable is excluded already.
  #
  # `\A`/`\z`, not `^`/`$`: `$` also matches immediately BEFORE a trailing
  # newline, which would have let the exact value that motivated this
  # through the new guard as well.
  @safe_redirect ~r{\A/[A-Za-z0-9._~/%?=&+,:@-]*\z}

  defp safe_path(path) when is_binary(path) do
    cond do
      String.starts_with?(path, "//") -> "/"
      Regex.match?(@safe_redirect, path) -> path
      true -> "/"
    end
  end

  defp safe_path(_other), do: "/"
end
