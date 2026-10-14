defmodule PairingsEngineWeb.ThemePackController do
  @moduledoc """
  Serves an installed theme pack's stylesheet and fonts, same-origin, so the
  Content-Security-Policy stays at `'self'` (`PairingsEngineWeb.CSP`):

    * `GET /themes/:id/theme.css`
    * `GET /themes/:id/fonts/:file`

  Strict on purpose. The id must name an accepted pack
  (`PairingsEngine.ThemePacks.get/1`, which has already scanned and
  size-capped the CSS); a font name must look like `[a-z0-9_-]+.woff2`,
  exist in that pack's `fonts/` and weigh at most a megabyte. Anything else
  is a plain 404 - no listing, no path that leaves the pack's folder, and no
  word about why.

  No pipeline in front of it: the sign-in page wears the theme too, so the
  files must load for a visitor, and there is nothing here a session would
  change.
  """
  use PairingsEngineWeb, :controller

  alias PairingsEngine.ThemePacks

  def css(conn, %{"id" => id}) do
    with %{} = pack <- ThemePacks.get(id),
         {:ok, css} <- read_capped(Path.join(pack.path, "theme.css"), ThemePacks.css_limit()) do
      serve(conn, "text/css; charset=utf-8", css, pack.etag)
    else
      _ -> not_found(conn)
    end
  end

  def font(conn, %{"id" => id, "file" => file}) do
    with true <- ThemePacks.font_file?(file),
         %{} = pack <- ThemePacks.get(id),
         path = Path.join([pack.path, "fonts", file]),
         {:ok, data} <- read_capped(path, ThemePacks.font_limit()) do
      etag = :crypto.hash(:sha256, data) |> binary_part(0, 8) |> Base.encode16(case: :lower)
      serve(conn, "font/woff2", data, etag)
    else
      _ -> not_found(conn)
    end
  end

  defp read_capped(path, limit) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when size <= limit -> File.read(path)
      _ -> :error
    end
  end

  defp serve(conn, type, body, etag) do
    etag = ~s("#{etag}")

    conn =
      conn
      |> put_resp_header("cache-control", "public, max-age=3600")
      |> put_resp_header("etag", etag)
      |> put_resp_header("x-content-type-options", "nosniff")

    if etag in get_req_header(conn, "if-none-match") do
      send_resp(conn, 304, "")
    else
      conn |> put_resp_content_type(type, nil) |> send_resp(200, body)
    end
  end

  defp not_found(conn), do: conn |> put_resp_content_type("text/plain") |> send_resp(404, "")
end
