defmodule PairingsEngineWeb.Plugs.English do
  @moduledoc """
  `PairingsEngineWeb.EnglishHook` for a plain controller: pins one request to
  English regardless of the visitor's chosen locale.

  Used on mobile enrolment - `/m`, `/m/e/:token` and `/m/leave`, served by
  `PairingsEngineWeb.MobileEnrollController`. Those are the phone's first
  page, and the page it lands on straight afterwards, mobile result entry,
  is already pinned by the hook. The hook cannot reach them: it is a
  `live_session` hook and these are controller routes. So `Plugs.Locale`
  won, and a Dutch session got an English card with a Dutch error line in
  it - the template is unwrapped English, and its five error lines are
  wrapped - followed by an all-English result entry page. The reasoning is
  the hook's, and so is the rule: player-facing pages are English.

  ## Request-scoped, and nothing else

  It runs after `Plugs.Locale`, which has already resolved the locale and
  written it into the session. This does not write anything back. The phone
  scanning the QR code may well be the arbiter's own, signed in to the admin
  screens in Dutch, and pinning the enrolment page must not change the
  language of those. So it sets the Gettext locale for this process and the
  `:locale` assign for this response, and leaves the session exactly as
  `Plugs.Locale` left it.

  The error lines stay wrapped in `gettext`. Under this plug they render the
  msgid, which is the English; if the decision is ever revisited, remove the
  plug from the router rather than re-wrapping anything.
  """
  alias PairingsEngineWeb.Locale

  def init(opts), do: opts

  def call(conn, _opts) do
    Gettext.put_locale(PairingsEngineWeb.Gettext, Locale.default())
    Plug.Conn.assign(conn, :locale, Locale.default())
  end
end
