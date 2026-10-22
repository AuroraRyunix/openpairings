defmodule PairingsEngineWeb.OldPublicPageController do
  @moduledoc """
  The public pages this app served until the split of 2026-08-29
  (`/p/:slug/pairings`, `/standings`, `/register`), which moved to the
  results site under the same slug. Removing them was right; leaving every
  link already printed on a wall chart, mailed to a club or pasted into a
  forum to die with a 404 was not. So they forward, permanently, to the
  page that replaced them.

  The slug is checked for shape and nothing else: the results site knows
  whether it exists, and this app answering "not found" on its behalf is how
  the links broke in the first place. The host is ours, never the request's,
  so this is not an open redirect.
  """
  use PairingsEngineWeb, :controller

  alias PairingsEngine.Publishing

  @slug ~r/\A[A-Za-z0-9_-]{6,64}\z/

  def show(conn, %{"slug" => slug}) do
    with true <- Regex.match?(@slug, slug), base when is_binary(base) <- base() do
      conn
      |> put_status(:moved_permanently)
      |> redirect(external: base <> "/t/" <> slug <> suffix(conn.private[:old_page]))
    else
      _not_a_slug_or_nowhere ->
        conn
        |> put_status(:not_found)
        |> put_view(html: PairingsEngineWeb.ErrorHTML)
        |> render("404.html")
    end
  end

  defp suffix("register"), do: "/register"
  defp suffix(_standings_or_pairings), do: ""

  defp base do
    case Publishing.public_base() || Publishing.default_public_server() do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _none -> nil
    end
  end
end
