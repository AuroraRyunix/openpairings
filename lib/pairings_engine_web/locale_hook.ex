defmodule PairingsEngineWeb.LocaleHook do
  @moduledoc """
  Applies the session's locale inside the LiveView's own process.

  This exists because a LiveView does not run in the process that served the
  request. `Gettext.put_locale/1` is per-process, so the plug's call reaches
  the dead render and nothing after it - the page would render translated,
  connect, and then re-render in the default language. That flicker is the
  bug this prevents.

  Listed on every `live_session` for the same reason
  `PairingsEngineWeb.DeployNotice` is: there is no central place that
  catches them all, and a session added later without it renders in English
  while the rest of the app is not. `locale_test.exs` walks the router and
  fails if one is missing.
  """
  alias PairingsEngineWeb.Locale

  def on_mount(:default, _params, session, socket) do
    # No `accept-language` here - a LiveView mount has no conn to read it
    # from. It does not need one: the plug already resolved the header and
    # wrote the answer into the session before this ever runs.
    locale = Locale.resolve(session)
    Gettext.put_locale(PairingsEngineWeb.Gettext, locale)

    {:cont, Phoenix.Component.assign(socket, locale: locale)}
  end
end
