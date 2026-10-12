defmodule PairingsEngineWeb.BoardRelayLiveTest do
  @moduledoc """
  Settings, Live boards, the card "The results site": what it says about the
  box's permission to send moves there, in each state, and that the arbiter
  is never asked to copy a key unless the results site cannot hand one out.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import PairingsEngine.BoardLinkFixtures

  alias PairingsEngine.{BoardLink, Publishing, Repo, Tournaments}
  alias PairingsEngine.BoardLink.RelayKeys
  alias PairingsEngine.PublicServerStub, as: Server

  @key_a "orrk_" <> String.duplicate("a", 39) <> "AAAA"
  @key_b "orrk_" <> String.duplicate("b", 39) <> "BBBB"

  setup :register_and_log_in_user

  setup %{scope: scope} do
    Publishing.put_endpoint("https://openresults.example/")
    Publishing.put_public_base(nil)
    Publishing.put_token("s3cret")
    slug = "relay-live-#{System.unique_integer([:positive])}"

    paired_tournament(scope, %{
      publish_to_openresults: true,
      openresults_key: "tk-#{slug}",
      public_slug: slug
    })
  end

  defp site(fun), do: Req.Test.stub(PairingsEngine.PublishingTest, fun)
  defp hands_out(key), do: site(&Server.json(&1, 201, %{"relay_key" => key}))
  defp answers(status, body), do: site(&Server.json(&1, status, body))

  defp open(conn, t) do
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/boards")
    lv
  end

  test "not on the results site: the one thing to do, and nothing about keys", %{
    conn: conn,
    tournament: t
  } do
    t |> Ecto.Changeset.change(publish_to_openresults: false) |> Repo.update!()
    lv = open(conn, t)

    assert has_element?(lv, "#boards-no-target a[href='/t/#{t.id}/settings/results']")
    refute has_element?(lv, "#boards-permission")
    refute has_element?(lv, "#relay-key-form")
  end

  test "on the site with no box in sight: nothing asked, nothing to paste", %{
    conn: conn,
    tournament: t
  } do
    lv = open(conn, t)

    assert has_element?(lv, "#boards-target")
    assert has_element?(lv, "#boards-permission[data-state='idle'] #relay-key-idle")
    refute has_element?(lv, "#relay-key-form")
    refute has_element?(lv, "#relay-key-retry")
  end

  test "a code is made: fetching, then - by itself - the box may send", %{
    conn: conn,
    tournament: t
  } do
    hands_out(@key_a)
    lv = open(conn, t)

    lv |> element("#tournament-codes-new") |> render_click()
    assert has_element?(lv, "#boards-permission[data-state='fetching'] #relay-key-fetching")
    refute has_element?(lv, "#relay-key-form")

    # The drain's pass. The page hears about it; nobody clicks anything.
    assert RelayKeys.sweep() == 1
    html = render(lv)

    assert has_element?(lv, "#boards-permission[data-state='held'] #relay-key-held")
    assert has_element?(lv, "#relay-key-origin", "AAAA")
    assert has_element?(lv, "#relay-key-replace")
    refute has_element?(lv, "#relay-key-form")
    refute has_element?(lv, "#relay-key-clear")
    # Its last four characters are small print; the key is nowhere.
    refute html =~ @key_a
  end

  test "offline: still fetching, and says it tries again by itself", %{
    conn: conn,
    scope: scope,
    tournament: t
  } do
    {:ok, _link, _secret} = BoardLink.create_link(scope, t)
    site(&Req.Test.transport_error(&1, :econnrefused))
    lv = open(conn, t)

    RelayKeys.sweep()
    render(lv)

    assert has_element?(lv, "#boards-permission[data-state='fetching']")
    assert has_element?(lv, "#relay-key-waiting")
    refute has_element?(lv, "#relay-key-retry")
    refute has_element?(lv, "#relay-key-form")
  end

  test "refused: the reason in words, Try again, and no paste field", %{
    conn: conn,
    scope: scope,
    tournament: t
  } do
    {:ok, _link, _secret} = BoardLink.create_link(scope, t)
    answers(403, %{"error" => "not_owner", "detail" => "Test."})
    RelayKeys.sweep()
    lv = open(conn, t)

    assert has_element?(lv, "#boards-permission[data-state='refused'] #relay-key-refused")
    assert lv |> element("#relay-key-refused") |> render() =~ "another publisher"
    refute has_element?(lv, "#relay-key-form")

    hands_out(@key_a)
    lv |> element("#relay-key-retry") |> render_click()
    assert has_element?(lv, "#boards-permission[data-state='fetching']")

    RelayKeys.sweep()
    render(lv)
    assert has_element?(lv, "#boards-permission[data-state='held']")
  end

  test "an older results site: says why, and only then offers to paste one", %{
    conn: conn,
    scope: scope,
    tournament: t
  } do
    {:ok, _link, _secret} = BoardLink.create_link(scope, t)
    answers(404, %{"errors" => %{"detail" => "Not Found"}})
    RelayKeys.sweep()
    lv = open(conn, t)

    assert has_element?(lv, "#boards-permission[data-state='refused']")
    assert lv |> element("#relay-key-refused") |> render() =~ "older version"
    assert has_element?(lv, "#relay-key-fallback #relay-key-form")
    assert has_element?(lv, "#relay-key-retry")

    lv |> form("#relay-key-form", relay: %{key: @key_b}) |> render_submit()

    assert has_element?(lv, "#boards-permission[data-state='held']")
    assert has_element?(lv, "#relay-key-origin", "BBBB")
    assert Tournaments.get_tournament!(t.id).openresults_relay_key == @key_b

    # A pasted one can be removed again; the page is back where it was.
    lv |> element("#relay-key-clear") |> render_click()
    assert Tournaments.get_tournament!(t.id).openresults_relay_key == nil
    assert has_element?(lv, "#boards-permission[data-state='refused']")
    assert has_element?(lv, "#relay-key-form")
  end

  test "Replace: the old one stays until the new one is here", %{
    conn: conn,
    scope: scope,
    tournament: t
  } do
    {:ok, _link, _secret} = BoardLink.create_link(scope, t)
    hands_out(@key_a)
    RelayKeys.sweep()
    lv = open(conn, t)

    hands_out(@key_b)
    lv |> element("#relay-key-replace") |> render_click()

    assert has_element?(lv, "#relay-key-replacing")
    assert has_element?(lv, "#relay-key-origin", "AAAA")
    refute has_element?(lv, "#relay-key-replace")

    RelayKeys.sweep()
    render(lv)

    assert has_element?(lv, "#relay-key-origin", "BBBB")
    refute has_element?(lv, "#relay-key-replacing")
    assert has_element?(lv, "#relay-key-replace")
  end

  test "switching the live link on is a reason to ask", %{conn: conn, tournament: t} do
    lv = open(conn, t)
    assert has_element?(lv, "#boards-permission[data-state='idle']")

    lv |> element("#boards-live-toggle") |> render_click()
    assert has_element?(lv, "#boards-permission[data-state='fetching']")
  end
end
