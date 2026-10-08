defmodule PairingsEngine.Accounts.Preferences do
  @moduledoc """
  The values an account may store for its interface language, colour theme
  and accent colour - `users.locale`, `users.theme`, `users.accent`.

  ## `nil` is a real answer, and the default

  Each of the three is nullable, and `nil` means "not stored on the account":

    * **language** - the browser decides (`accept-language`, or whatever was
      picked on this device), exactly as for a visitor with no account;
    * **theme, accent** - each device keeps its own, in its own browser
      storage, as it always has.

  A stored value follows the person to every device they sign in on. The
  split is deliberate: a language is a fact about the person, a dark theme
  on the laptop at night and a light one on the club's projector is a fact
  about the screen, and forcing one answer on both would be wrong for
  somebody.

  ## Where the lists come from

  Duplicated from the three places that render them, because this is the
  one place that must refuse anything else: the theme and accent pickers in
  `PairingsEngineWeb.Layouts` (`@themes`, `@accents`), the `known` set in
  the root layout's inline script, and `PairingsEngineWeb.Locale`. A value
  outside these lists would be written into `data-theme` on every page the
  account opens - which is the exact failure the inline script's `known`
  set exists to catch for a stale browser value, and there is no reason to
  let the database be a second source of one.

  `"system"` is a theme here and not the same as `nil`: it says "follow the
  operating system's light/dark setting, on every device", where `nil` says
  "leave each device alone".
  """

  @themes ~w(system light dark slate paper board tomw contrast)
  @accents ~w(green blue teal violet rose slate indigo cyan fuchsia)

  @doc "Every theme an account may store, `\"system\"` first."
  def themes, do: @themes

  @doc "Every accent colour an account may store, the default (`green`) first."
  def accents, do: @accents

  @doc "Every interface language an account may store."
  def locales, do: PairingsEngineWeb.Locale.codes()

  @doc "Whether `value` may be stored as a theme."
  def theme?(value), do: value in @themes

  @doc "Whether `value` may be stored as an accent colour."
  def accent?(value), do: value in @accents

  @doc "Whether `value` may be stored as an interface language."
  def locale?(value), do: value in locales()
end
