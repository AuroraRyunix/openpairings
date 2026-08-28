defmodule PairingsEngineWeb.PublicLink do
  @moduledoc """
  Where the public reads a tournament.

  There are two possible answers and the app must never guess wrong, because
  the wrong one is not a broken link - it is a working link to the machine the
  arbiter is trying to pair on, which is the exact thing the split exists to
  avoid.

  ## The rule

  A tournament that publishes to OpenResults is read **there**. Everything
  else is read from this app's own public pages.

  That is the whole reason OpenResults exists: an arbiter's tool and a
  spectator's page want opposite things, and a popular open's standings page
  should not be served by the laptop running the round. Handing out a
  `/p/:slug` link for a tournament that is being published would send every
  spectator back to that laptop and quietly undo the split, while looking
  entirely fine.

  ## Why the local pages stay

  Publishing is opt-in per machine AND per tournament, and this app also runs
  on a laptop with no OpenResults anywhere near it. A tournament that has not
  opted in still needs a public link, so `/p/:slug/...` is not going away -
  it just stops being advertised the moment there is somewhere better.

  ## Why the targets are coarse

  OpenResults has its own navigation and its own URL shape (`/t/:slug`,
  `/t/:slug/round/:n`). Deep-linking from here into that structure would tie
  the two apps together far more tightly than the snapshot contract does -
  a route rename over there would break links printed on paper over here. So
  a published tournament gets its front page and finds its own way from
  there; only registration, which is a distinct destination rather than a
  view of the same thing, is addressed directly.
  """

  alias PairingsEngine.Publishing
  alias PairingsEngine.Tournaments.Tournament
  alias PairingsEngineWeb.Endpoint

  @type target :: :standings | :pairings | :register

  @doc """
  The URL to hand a spectator, as a full absolute address.

  Absolute rather than a path because half of these end up on a QR code, in a
  printed footer, or pasted into an email, and a relative link is useless in
  all three.
  """
  @spec url(Tournament.t(), target()) :: String.t()
  def url(%Tournament{} = tournament, target \\ :standings) do
    case remote_base(tournament) do
      nil -> local_url(tournament, target)
      base -> remote_url(base, tournament, target)
    end
  end

  @doc """
  Whether this tournament's public links point at OpenResults.

  For telling the arbiter which site they are about to share, which matters:
  the two look nothing alike, and somebody checking a link before printing it
  should not have to compare hostnames to work out which one they got.
  """
  @spec published?(Tournament.t()) :: boolean()
  def published?(%Tournament{} = tournament), do: not is_nil(remote_base(tournament))

  @doc "The host a spectator will land on, for showing beside a link."
  @spec host(Tournament.t()) :: String.t()
  def host(%Tournament{} = tournament) do
    tournament |> url() |> URI.parse() |> Map.get(:host) || ""
  end

  # Both halves have to be true. The switch alone is a promise about the
  # future - a tournament can be marked to publish on a machine that has no
  # address configured yet, and sending a spectator to a blank address would
  # be worse than sending them to the local page.
  defp remote_base(%Tournament{publish_to_openresults: true}) do
    case Publishing.endpoint() do
      endpoint when is_binary(endpoint) and endpoint != "" ->
        String.trim_trailing(endpoint, "/")

      _unset ->
        nil
    end
  end

  defp remote_base(%Tournament{}), do: nil

  defp remote_url(base, %Tournament{public_slug: slug}, :register),
    do: "#{base}/t/#{URI.encode_www_form(slug)}/register"

  defp remote_url(base, %Tournament{public_slug: slug}, _target),
    do: "#{base}/t/#{URI.encode_www_form(slug)}"

  defp local_url(%Tournament{public_slug: slug}, target) do
    Endpoint.url() <> "/p/" <> URI.encode_www_form(slug) <> "/" <> local_path(target)
  end

  defp local_path(:pairings), do: "pairings"
  defp local_path(:register), do: "register"
  defp local_path(_standings), do: "standings"
end
