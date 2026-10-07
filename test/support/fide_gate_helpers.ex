defmodule PairingsEngineWeb.FideGateHelpers do
  @moduledoc """
  Answers TEC's Level-4 double confirmation the way an arbiter who means it
  does (VCL4THP Q43): "continue" on the first message, "leave" on the second.
  A page that is not asking is left alone, so a test can call this after
  any action that may or may not depart from FIDE mode. Returns the page's
  HTML.
  """
  import Phoenix.LiveViewTest

  def confirm_fide_exit(lv, prefix \\ "fide-gate") do
    if has_element?(lv, "##{prefix}-warn") do
      lv |> element("##{prefix}-continue") |> render_click()
      lv |> element("##{prefix}-confirm") |> render_click()
    end

    render(lv)
  end
end
