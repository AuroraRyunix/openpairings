defmodule PairingsEngineWeb.PublicLink do
  @moduledoc """
  Where the public reads a tournament.

  There is exactly one answer - the results site - and for most tournaments
  the answer is "nowhere". This app stopped serving public pages on
  2026-08-29; a tournament that does not publish has no public address at
  all, and this module's job is to say so rather than invent one.

  ## Why there is no local answer any more

  The app used to serve `/p/:slug/pairings` and friends, so every tournament
  had a public link whether or not it published. That was two public
  surfaces for one thing, and the wrong one was the default: a link to the
  arbiter's laptop, handed to a hall full of spectators, is precisely what
  the split with OpenResults exists to prevent. Rather than keep choosing
  correctly between them at six call sites, there is now one.

  ## The two halves

  `public?/1` asks whether there is a link at all; `url/2` returns it, or
  `nil`. Callers gate on the first and then use the second - and in markup
  that means `:if={PublicLink.public?(@t)}` on the element that carries the
  `href`, not a bare `url/2` that would render an `<a>` pointing nowhere.

  Note `PairingsEngine.Publishing.published?/1` answers a *different*
  question - "is a copy of this out there right now" - and the two disagree
  in both directions on purpose. A tournament switched off after publishing
  is `published?` but not `public?` (a copy is still up, but this machine no
  longer advertises it, and the arbiter is offered a takedown instead); one
  switched on that has not yet sent anything is `public?` but not
  `published?`.

  ## Why the targets are coarse

  OpenResults has its own navigation and its own URL shape (`/t/:slug`,
  `/t/:slug/round/:n`). Deep-linking from here into that structure would tie
  the two apps together far more tightly than the snapshot contract does - a
  route rename over there would break links printed on paper over here. So a
  tournament gets its front page and the reader finds their own way; only
  registration, a distinct destination rather than a view of the same thing,
  is addressed directly.
  """

  alias PairingsEngine.Publishing
  alias PairingsEngine.Tournaments.Tournament

  @type target :: :standings | :pairings | :register

  @doc """
  Whether this tournament has a public address at all.

  Both halves have to be true: the arbiter switched publishing on, AND this
  machine knows where the results site is. The switch alone is a promise
  about the future - a tournament can be marked to publish on a machine that
  has not been told an address yet - and offering a link built from a blank
  address is worse than offering none.
  """
  @spec public?(Tournament.t()) :: boolean()
  def public?(%Tournament{} = tournament), do: not is_nil(base(tournament))

  @doc """
  The URL to hand a spectator, or `nil` if this tournament has none.

  Absolute rather than a path: it points at another host, and half of these
  end up on a QR code, in a printed footer, or pasted into an email.
  """
  @spec url(Tournament.t(), target()) :: String.t() | nil
  def url(%Tournament{} = tournament, target \\ :standings) do
    case base(tournament) do
      nil -> nil
      base -> base <> path(tournament, target)
    end
  end

  @doc """
  The host a spectator will land on, for naming the site beside a link.

  `nil` when there is no link. Worth showing: the arbiter's own machine and
  the results site look nothing alike, and somebody checking a link before
  printing it should not have to read a URL to work out which one they got.
  """
  @spec host(Tournament.t()) :: String.t() | nil
  def host(%Tournament{} = tournament) do
    case url(tournament) do
      nil -> nil
      url -> URI.parse(url).host
    end
  end

  defp base(%Tournament{publish_to_openresults: true}) do
    case Publishing.endpoint() do
      endpoint when is_binary(endpoint) and endpoint != "" ->
        String.trim_trailing(endpoint, "/")

      _unset ->
        nil
    end
  end

  defp base(%Tournament{}), do: nil

  defp path(%Tournament{public_slug: slug}, :register),
    do: "/t/#{URI.encode_www_form(slug)}/register"

  defp path(%Tournament{public_slug: slug}, _front_page),
    do: "/t/#{URI.encode_www_form(slug)}"
end
