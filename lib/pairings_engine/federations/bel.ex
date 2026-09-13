defmodule PairingsEngine.Federations.BEL do
  @moduledoc """
  Which of the three ways to fill `kbsb_players` this installation should
  offer right now, in order:

    1. `:data_platform` - `KBSB_API_URL`/`KBSB_API_KEY` configured
       (`PairingsEngine.Federations.BEL.Api.configured?/0`). What the hosted
       server always uses, and what a desktop install uses too if somebody
       set those env vars on it directly.
    2. `:results_site` - no data-platform key, but a working connection to
       OpenResults (`PairingsEngine.Federations.BEL.ResultsSource.available?/0`).
       The desktop answer: this installation's own credential, relayed
       through a server that holds the real KBSB key.
    3. `:file_upload` - neither of the above. The original fallback, and
       the only option on an installation with no network path to either
       source.

  Nothing here changes what any of the three sources actually does; this is
  only the one place that decides which button the rating-lists page (and
  the Connections page's wording) should show. See docs/kbsb-sync.md.
  """

  alias PairingsEngine.Federations.BEL.{Api, ResultsSource}

  @type source :: :data_platform | :results_site | :file_upload

  @spec source() :: source()
  def source do
    cond do
      Api.configured?() -> :data_platform
      ResultsSource.available?() -> :results_site
      true -> :file_upload
    end
  end
end
