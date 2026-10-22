defmodule PairingsEngineWeb.ErrorHTMLTest do
  use PairingsEngineWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  test "renders 404.html with a way back" do
    html = render_to_string(PairingsEngineWeb.ErrorHTML, "404", "html", [])
    assert html =~ "error-page"
    assert html =~ ~s(href="/")
  end

  test "400 shares the 404 page" do
    assert render_to_string(PairingsEngineWeb.ErrorHTML, "400", "html", []) =~ "error-back-link"
  end

  test "renders 500.html with a way back" do
    html = render_to_string(PairingsEngineWeb.ErrorHTML, "500", "html", [])
    assert html =~ "error-back-link"
  end

  test "403 is a page with a way back too" do
    assert render_to_string(PairingsEngineWeb.ErrorHTML, "403", "html", []) =~ "error-back-link"
  end

  test "other statuses stay plain text" do
    assert render_to_string(PairingsEngineWeb.ErrorHTML, "422", "html", []) ==
             Phoenix.Controller.status_message_from_template("422.html")
  end
end
