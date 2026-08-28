defmodule PairingsEngineWeb.PublicLinkTest do
  @moduledoc """
  Where the app sends a spectator.

  The wrong answer here is not a broken link. It is a working link to the
  machine the arbiter is pairing on, which is the exact thing the split
  exists to avoid - and it looks completely fine while doing it.
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

  defp tournament(attrs \\ []) do
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
    test "is read from this machine" do
      t = tournament(publish_to_openresults: false)

      assert PublicLink.url(t, :standings) =~ "/p/#{t.public_slug}/standings"
      assert PublicLink.url(t, :pairings) =~ "/p/#{t.public_slug}/pairings"
      assert PublicLink.url(t, :register) =~ "/p/#{t.public_slug}/register"
      refute PublicLink.published?(t)
    end

    test "is read from this machine even when a results site is configured" do
      Publishing.put_endpoint("https://openresults.example")
      Publishing.put_token("s3cret")

      t = tournament(publish_to_openresults: false)

      # Publishing is opt-in per tournament. A machine having somewhere to
      # publish says nothing about whether THIS event goes there.
      assert PublicLink.url(t) =~ "/p/#{t.public_slug}/standings"
      refute PublicLink.published?(t)
    end
  end

  describe "a published tournament" do
    setup do
      Publishing.put_endpoint("https://openresults.example")
      Publishing.put_token("s3cret")
      :ok
    end

    test "is read from the results site, not from here" do
      t = tournament(publish_to_openresults: true)

      assert PublicLink.url(t, :standings) == "https://openresults.example/t/#{t.public_slug}"
      assert PublicLink.published?(t)
      assert PublicLink.host(t) == "openresults.example"
    end

    test "never hands out a link back to this machine" do
      t = tournament(publish_to_openresults: true)

      # The failure this whole module exists to prevent: a spectator sent to
      # the laptop running the round.
      for target <- [:standings, :pairings, :register] do
        refute PublicLink.url(t, target) =~ "/p/"
      end
    end

    test "registration is addressed directly, everything else gets the front page" do
      t = tournament(publish_to_openresults: true)

      assert PublicLink.url(t, :register) ==
               "https://openresults.example/t/#{t.public_slug}/register"

      # Deep-linking into the other app's URL shape would tie the two together
      # more tightly than the contract does - a route rename there would break
      # links printed on paper here.
      assert PublicLink.url(t, :pairings) == "https://openresults.example/t/#{t.public_slug}"
    end

    test "a trailing slash on the configured address does not double up" do
      Publishing.put_endpoint("https://openresults.example/")
      t = tournament(publish_to_openresults: true)

      refute PublicLink.url(t) =~ "//t/"
    end
  end

  describe "the switch on, but nowhere to publish to" do
    test "falls back to this machine rather than to a blank address" do
      t = tournament(publish_to_openresults: true)

      # Both halves have to be true. The switch alone is a promise about the
      # future: a tournament can be marked to publish on a machine that has
      # no address yet, and a link to nowhere is worse than a local one.
      assert PublicLink.url(t) =~ "/p/#{t.public_slug}/standings"
      refute PublicLink.published?(t)
    end
  end
end
