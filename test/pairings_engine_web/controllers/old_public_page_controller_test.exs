defmodule PairingsEngineWeb.OldPublicPageControllerTest do
  use PairingsEngineWeb.ConnCase, async: true

  alias PairingsEngine.Publishing

  defp base do
    (Publishing.public_base() || Publishing.default_public_server()) |> String.trim_trailing("/")
  end

  test "an old standings or pairings link forwards to the results site, permanently", %{
    conn: conn
  } do
    for page <- ~w(standings pairings) do
      conn = get(conn, "/p/rAwIcp1EOdKA/#{page}")
      assert conn.status == 301
      assert redirected_to(conn, 301) == base() <> "/t/rAwIcp1EOdKA"
    end
  end

  test "an old registration link forwards to the registration form", %{conn: conn} do
    conn = get(conn, "/p/rAwIcp1EOdKA/register")
    assert redirected_to(conn, 301) == base() <> "/t/rAwIcp1EOdKA/register"
  end

  test "something that is not a slug is not forwarded anywhere", %{conn: conn} do
    conn = get(conn, "/p/a.b/standings")
    assert conn.status == 404
  end
end
