defmodule PairingsEngine.Federations.BEL.Settings do
  @moduledoc """
  The two machine-wide settings that drive the Belgian rating-list sync -
  stored in `meta` (see `PairingsEngine.Meta`), editable on the Connections
  page, identical on hosted and desktop.

  ## Belgian rating list URL

  Defaults to KBSB's own public template,
  `https://www.frbe-kbsb.be/sites/manager/ELO/players_{YYYYMM}.zip` - the
  federation publishes the full roster there every month (e.g.
  `players_202608.zip` for August 2026). `{YYYYMM}` is expanded by
  `PairingsEngine.Federations.BEL.Http.resolve_url/2`; a value with no
  `{YYYYMM}` placeholder is used exactly as given, unchanged from month to
  month (a fixed mirror, or a pinned single-month file).

  ## Belgian club names URL

  Optional, and blank by default. A second, independent file the
  federation (or whoever maintains this) can publish separately - see
  `PairingsEngine.Federations.BEL.Clubs` for the two accepted formats. No
  placeholder expansion: unlike the players list this isn't dated, so the
  URL is used exactly as configured.
  """

  alias PairingsEngine.Meta

  @players_url_key "bel_players_url"
  @clubs_url_key "bel_clubs_url"

  @default_players_url "https://www.frbe-kbsb.be/sites/manager/ELO/players_{YYYYMM}.zip"

  @doc "The configured (or default) Belgian rating list URL/template."
  def players_url, do: Meta.get(@players_url_key) || @default_players_url

  @doc "The built-in default, for the settings form's placeholder/reset."
  def default_players_url, do: @default_players_url

  def put_players_url(nil), do: Meta.delete(@players_url_key)
  def put_players_url(""), do: Meta.delete(@players_url_key)
  def put_players_url(url) when is_binary(url), do: Meta.put(@players_url_key, url)

  @doc "The configured Belgian club names URL, or `nil` if none is set."
  def clubs_url, do: Meta.get(@clubs_url_key)

  def put_clubs_url(nil), do: Meta.delete(@clubs_url_key)
  def put_clubs_url(""), do: Meta.delete(@clubs_url_key)
  def put_clubs_url(url) when is_binary(url), do: Meta.put(@clubs_url_key, url)
end
