defmodule PairingsEngineWeb.BrandMarkTest do
  @moduledoc """
  The hosted server and a desktop install wear different marks, so a glance
  at the header or the browser tab says which copy of OpenPairings this is.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngineWeb.Layouts

  setup do
    previous = Application.get_env(:pairings_engine, :local_mode)
    on_exit(fn -> Application.put_env(:pairings_engine, :local_mode, previous) end)
    :ok
  end

  test "the hosted server shows the aurora mark and favicon" do
    Application.put_env(:pairings_engine, :local_mode, false)

    assert render_component(&Layouts.brand_mark/1, %{}) =~ "bm-aurora-orb"

    html = build_conn() |> get(~p"/users/log-in") |> html_response(200)
    icons = Regex.scan(~r/<link[^>]*rel="icon"[^>]*>/s, html)
    assert length(icons) == 1
    [_, b64] = Regex.run(~r/base64,([A-Za-z0-9+\/=]+)/, hd(hd(icons)))
    assert Base.decode64!(b64) =~ "orb-aurora"
    refute render_component(&Layouts.brand_mark/1, %{}) =~ ~s(id="bm-orb")
  end

  test "a desktop install keeps the original green mark" do
    Application.put_env(:pairings_engine, :local_mode, true)

    mark = render_component(&Layouts.brand_mark/1, %{})
    assert mark =~ ~s(id="bm-orb")
    refute mark =~ "bm-aurora-orb"
  end
end
