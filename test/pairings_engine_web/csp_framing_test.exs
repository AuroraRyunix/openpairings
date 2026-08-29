defmodule PairingsEngineWeb.CSPFramingTest do
  @moduledoc """
  Nothing this app serves may be framed.

  It used to vary: three read-only public pages opted out of
  `frame-ancestors 'none'` so a club site could embed the pairing list. They
  were removed on 2026-08-29 with the rest of the local public pages, and the
  opt-out mechanism (`CSP.allow_framing/2` and the router's `:embeddable`
  pipeline) went with them - a club embeds from OpenResults now, a site with
  no login and nothing to clickjack.

  So the rule is finally unconditional, and this is the test that keeps it
  that way. A regression that re-opened framing would not break a single
  feature; it would quietly make every logged-in arbiter clickjackable, and
  nothing else in the suite would notice.
  """
  use PairingsEngineWeb.ConnCase, async: true

  defp csp(conn), do: conn |> get_resp_header("content-security-policy") |> List.first()

  test "the login page refuses framing", %{conn: conn} do
    conn = get(conn, ~p"/users/log-in")

    assert csp(conn) =~ "frame-ancestors 'none'"
  end

  test "the public arbiter tools refuse framing", %{conn: conn} do
    conn = get(conn, ~p"/tools")

    assert csp(conn) =~ "frame-ancestors 'none'"
  end

  test "a redirect away from an authenticated page still carries the header", %{conn: conn} do
    # The header is set in the pipeline, so it is on the 302 as well as the
    # page - which matters, because a framed redirect is still framed.
    conn = get(conn, ~p"/")

    assert csp(conn) =~ "frame-ancestors 'none'"
  end

  test "no route can re-open framing, because nothing can ask any more" do
    refute function_exported?(PairingsEngineWeb.CSP, :allow_framing, 2)
  end

  test "x-frame-options is never contradicted by a leftover header", %{conn: conn} do
    conn = get(conn, ~p"/users/log-in")

    # If something ever sets `SAMEORIGIN`, browsers that prefer the older
    # header would use it instead of the CSP. Nothing should set one at all.
    assert get_resp_header(conn, "x-frame-options") == []
  end
end
