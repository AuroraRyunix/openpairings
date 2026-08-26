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

    socket =
      socket
      |> Phoenix.Component.assign(locale: locale)
      |> Phoenix.LiveView.attach_hook(:current_path, :handle_params, &put_current_path/3)

    {:cont, socket}
  end

  # The language picker sends the visitor back where they were, via
  # `LocaleController`'s `redirect_to`. Both layouts build that from
  # `assigns[:current_path] || "/"` - and nothing in the app ever assigned
  # `:current_path`, so the fallback was always taken and every language
  # switch dumped the visitor on `/`.
  #
  # That also made `LocaleController`'s whole `redirect_to` mechanism dead in
  # practice, including its protocol-relative-URL guard, which is why
  # `locale_test.exs` could exercise the controller directly and still miss
  # this: the controller worked, its only real caller never used it.
  #
  # Worst on the public pages, which anonymous visitors reach - `/` needs
  # authentication, so switching language there bounced them to the log-in
  # page instead of translating the page they were reading.
  #
  # Attached here rather than in each LiveView because this hook is already
  # on every `live_session` and `locale_test.exs` walks the router to prove
  # it: one place that is already guaranteed to be everywhere.
  defp put_current_path(_params, uri, socket) do
    {:cont, Phoenix.Component.assign(socket, :current_path, path_of(uri))}
  end

  # Path plus query, so a switch made on a filtered page comes back to the
  # same filter rather than to the bare page.
  defp path_of(uri) when is_binary(uri) do
    parsed = URI.parse(uri)

    case {parsed.path, parsed.query} do
      {nil, _} -> "/"
      {path, nil} -> path
      {path, query} -> path <> "?" <> query
    end
  end

  defp path_of(_), do: "/"
end
