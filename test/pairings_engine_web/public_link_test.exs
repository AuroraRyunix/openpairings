defmodule PairingsEngineWeb.PublicLinkTest do
  @moduledoc """
  Where the app sends a spectator.

  Until 2026-08-29 the danger here was handing out a link to the arbiter's
  own machine - a working link, to the computer running the round, which is
  the exact thing the split exists to avoid. Those pages are gone, so the
  danger has changed shape rather than disappeared: what must never happen
  now is a link that goes nowhere. A tournament with no public address has
  to say so, so the caller can leave the button out, rather than render an
  `<a href>` built from a blank endpoint.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Publishing, Repo}
  alias PairingsEngine.Tournaments.Tournament
  alias PairingsEngineWeb.PublicLink

  setup do
    Publishing.put_endpoint(nil)
    Publishing.put_token(nil)
    :ok
  end

  defp tournament(attrs) do
    Repo.insert!(
      struct(
        %Tournament{
          name: "T",
          type: "swiss",
          rounds_count: 3,
          public_slug: "slug-#{System.unique_integer([:positive])}"
        },
        attrs
      )
    )
  end

  describe "a tournament that does not publish" do
    test "has no public address at all" do
      t = tournament(publish_to_openresults: false)

      refute PublicLink.public?(t)
      assert PublicLink.url(t, :standings) == nil
      assert PublicLink.url(t, :pairings) == nil
      assert PublicLink.url(t, :register) == nil
      assert PublicLink.host(t) == nil
    end

    test "still has none when a results site IS configured" do
      Publishing.put_endpoint("https://results.example.org")
      t = tournament(publish_to_openresults: false)

      refute PublicLink.public?(t)
      assert PublicLink.url(t) == nil
    end
  end

  describe "a published tournament" do
    setup do
      Publishing.put_endpoint("https://results.example.org")
      {:ok, t: tournament(publish_to_openresults: true)}
    end

    test "is read on the results site", %{t: t} do
      assert PublicLink.public?(t)
      assert PublicLink.url(t, :standings) == "https://results.example.org/t/#{t.public_slug}"
      assert PublicLink.host(t) == "results.example.org"
    end

    test "sends registration to the form rather than the front page", %{t: t} do
      assert PublicLink.url(t, :register) ==
               "https://results.example.org/t/#{t.public_slug}/register"

      # Everything else is deliberately the front page - see the moduledoc on
      # why this app does not deep-link into the other one's routes.
      assert PublicLink.url(t, :pairings) == PublicLink.url(t, :standings)
    end

    test "never hands out a link back to this machine", %{t: t} do
      own_host = URI.parse(PairingsEngineWeb.Endpoint.url()).host

      for target <- [:standings, :pairings, :register] do
        url = PublicLink.url(t, target)

        refute url =~ "/p/"
        refute URI.parse(url).host == own_host
      end
    end
  end

  describe "an endpoint that is set but unusable" do
    test "switched on with no endpoint configured is not public" do
      t = tournament(publish_to_openresults: true)

      # The switch is a promise about the future, not an address. A link
      # built from a blank endpoint would be `/t/slug` - a relative path that
      # resolves against whatever page it was rendered on, i.e. straight back
      # to this machine, which is exactly the old bug wearing a new hat.
      refute PublicLink.public?(t)
      assert PublicLink.url(t) == nil
    end

    test "a trailing slash does not produce a doubled one" do
      Publishing.put_endpoint("https://results.example.org/")
      t = tournament(publish_to_openresults: true)

      assert PublicLink.url(t) == "https://results.example.org/t/#{t.public_slug}"
    end
  end
end
