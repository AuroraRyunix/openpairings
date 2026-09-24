defmodule PairingsEngine.Badges.FideProfileProxyTest do
  # Not async: these tests change application config the FIDE fetch reads.
  use ExUnit.Case, async: false

  alias PairingsEngine.Badges.FideProfile

  setup do
    previous = Application.get_env(:pairings_engine, :fide_photo_proxy)
    on_exit(fn -> Application.put_env(:pairings_engine, :fide_photo_proxy, previous) end)
    :ok
  end

  defp proxy(url, token),
    do: Application.put_env(:pairings_engine, :fide_photo_proxy, url: url, token: token)

  test "without a relay configured, requests go to FIDE unchanged" do
    proxy(nil, nil)
    url = "https://ratings.fide.com/profile/255424"
    assert FideProfile.via_proxy(url) == {url, []}
  end

  test "a URL without a token is not a relay: both or neither" do
    proxy("https://relay.example.workers.dev", nil)
    url = "https://ratings.fide.com/profile/255424"
    assert FideProfile.via_proxy(url) == {url, []}
  end

  test "the profile page goes to the relay's /profile route, with the token" do
    proxy("https://relay.example.workers.dev/", "s3cret")

    assert FideProfile.via_proxy("https://ratings.fide.com/profile/255424") ==
             {"https://relay.example.workers.dev/profile/255424", [{"x-proxy-token", "s3cret"}]}
  end

  test "a photo file goes to the relay's /photo route, its URL encoded" do
    proxy("https://relay.example.workers.dev", "s3cret")

    {url, headers} = FideProfile.via_proxy("https://ratings.fide.com/card.phtml?photo=1&id=2")

    assert url ==
             "https://relay.example.workers.dev/photo?url=https%3A%2F%2Fratings.fide.com%2Fcard.phtml%3Fphoto%3D1%26id%3D2"

    assert headers == [{"x-proxy-token", "s3cret"}]
  end
end
