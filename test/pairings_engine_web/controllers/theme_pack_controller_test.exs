defmodule PairingsEngineWeb.ThemePackControllerTest do
  use PairingsEngineWeb.ConnCase, async: false

  import PairingsEngine.ThemePackFixtures

  alias PairingsEngine.ThemePacks

  setup :themes_dir

  @woff2 "wOF2" <> String.duplicate("\0", 60)

  test "serves an installed pack's stylesheet, cacheably", %{conn: conn, themes_dir: dir} do
    install_pack(dir, "toon")
    [pack] = ThemePacks.list()

    conn = get(conn, ~p"/themes/toon/theme.css")
    assert response(conn, 200) == good_css("toon")
    assert response_content_type(conn, :css) =~ "text/css"
    assert [etag] = get_resp_header(conn, "etag")
    assert etag == ~s("#{pack.etag}")
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

    again =
      build_conn() |> put_req_header("if-none-match", etag) |> get(~p"/themes/toon/theme.css")

    assert again.status == 304
  end

  test "serves a whitelisted font from the pack", %{conn: conn, themes_dir: dir} do
    install_pack(dir, "toon", fonts: %{"toon-latin.woff2" => @woff2})

    conn = get(conn, ~p"/themes/toon/fonts/toon-latin.woff2")
    assert response(conn, 200) == @woff2
    assert get_resp_header(conn, "content-type") == ["font/woff2"]
  end

  test "is a plain 404 for anything else", %{conn: conn, themes_dir: dir} do
    install_pack(dir, "toon",
      fonts: %{
        "big.woff2" => String.duplicate("x", ThemePacks.font_limit() + 1),
        "Upper.woff2" => @woff2,
        "font.ttf" => "x"
      }
    )

    install_pack(dir, "evil", css: "body { color: red; }")
    File.write!(Path.join(dir, "secret.txt"), "no")

    for path <- [
          "/themes/nope/theme.css",
          "/themes/evil/theme.css",
          "/themes/TOON/theme.css",
          "/themes/toon/fonts/missing.woff2",
          "/themes/toon/fonts/big.woff2",
          "/themes/toon/fonts/Upper.woff2",
          "/themes/toon/fonts/font.ttf",
          "/themes/toon/fonts/..%2Ftheme.json",
          "/themes/toon/fonts/..%2F..%2Fsecret.txt",
          "/themes/..%2Fsecret.txt/theme.css"
        ] do
      assert build_conn() |> get(path) |> Map.fetch!(:status) == 404, "served #{path}"
    end

    _ = conn
  end

  test "stops serving a pack the moment it is removed", %{conn: conn, themes_dir: dir} do
    path = install_pack(dir, "toon")
    assert get(conn, ~p"/themes/toon/theme.css").status == 200

    File.rm_rf!(path)
    assert build_conn() |> get(~p"/themes/toon/theme.css") |> Map.fetch!(:status) == 404
  end
end
