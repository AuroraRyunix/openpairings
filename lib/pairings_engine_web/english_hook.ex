defmodule PairingsEngineWeb.EnglishHook do
  @moduledoc """
  Pins a page to English regardless of the visitor's chosen locale.

  Used on the player-facing pages - the public pairings and standings, the
  registration form, and mobile result entry.

  The reasoning is not that these pages matter less. It is that they have a
  different audience: an open draws players from a dozen federations, and
  the language a Belgian arbiter picked for their own admin screens is not a
  sensible thing to impose on a Polish player reading the standings. English
  is the one language that room mostly shares.

  The arbiter UI is the opposite case - one person, usually local, running
  the event in their own language.

  This is a DELIBERATE pin, not an absence of translation. Wrapping strings
  on these pages would still leave them English while this hook is here; if
  the decision is ever revisited, remove the hook from the router rather
  than hunting for missing `gettext` calls that were never the cause.
  """
  alias PairingsEngineWeb.Locale

  def on_mount(:default, _params, _session, socket) do
    Gettext.put_locale(PairingsEngineWeb.Gettext, Locale.default())

    {:cont, Phoenix.Component.assign(socket, locale: Locale.default())}
  end
end
