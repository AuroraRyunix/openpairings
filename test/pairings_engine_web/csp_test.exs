defmodule PairingsEngineWeb.CSPTest do
  use PairingsEngineWeb.ConnCase, async: true

  setup :register_and_log_in_user

  defp csp(conn), do: conn |> get_resp_header("content-security-policy") |> List.first()

  test "every browser response carries a policy", %{conn: conn} do
    policy = conn |> get(~p"/users/log-in") |> csp()

    assert policy =~ "default-src 'self'"
    assert policy =~ "object-src 'none'"
    assert policy =~ "frame-ancestors 'none'"
    assert policy =~ "base-uri 'self'"
    assert policy =~ "form-action 'self'"
    # data: URIs carry the favicon, the QR codes and the print logo.
    assert policy =~ "img-src 'self' data:"
  end

  test "script-src allows the bundle and a nonce, but not arbitrary inline script", %{conn: conn} do
    policy = conn |> get(~p"/users/log-in") |> csp()

    assert policy =~ ~r/script-src 'self' 'nonce-[A-Za-z0-9+\/=]+'/
    refute policy =~ "script-src 'self' 'unsafe-inline'"
    refute policy =~ "'unsafe-eval'"
  end

  test "the root layout's inline bootstrap carries the same nonce the header allows", %{
    conn: conn
  } do
    conn = get(conn, ~p"/users/log-in")
    html = html_response(conn, 200)

    ["nonce-" <> rest] = Regex.run(~r/nonce-[A-Za-z0-9+\/=]+/, csp(conn))
    nonce = String.trim_trailing(rest, "'")

    assert html =~ ~s(<script nonce="#{nonce}">)
  end

  test "a LiveView page gets a nonce its layout can use too", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    ["nonce-" <> rest] = Regex.run(~r/nonce-[A-Za-z0-9+\/=]+/, csp(conn))
    nonce = String.trim_trailing(rest, "'")

    assert html =~ ~s(<script nonce="#{nonce}">)
  end

  test "the nonce changes per response, so a leaked one is useless", %{conn: conn} do
    first = conn |> get(~p"/users/log-in") |> csp()
    second = conn |> get(~p"/users/log-in") |> csp()

    assert first != second
  end

  test "print pages carry their auto-print script's nonce", %{conn: conn, scope: scope} do
    {:ok, tournament} =
      PairingsEngine.Tournaments.create_tournament(scope, %{
        "name" => "CSP Print",
        "type" => "swiss",
        "rounds_count" => "3"
      })

    conn = get(conn, ~p"/t/#{tournament.id}/print/players")
    html = html_response(conn, 200)

    ["nonce-" <> rest] = Regex.run(~r/nonce-[A-Za-z0-9+\/=]+/, csp(conn))
    nonce = String.trim_trailing(rest, "'")

    assert html =~ ~s(<script nonce="#{nonce}">window.onload)
  end
end
