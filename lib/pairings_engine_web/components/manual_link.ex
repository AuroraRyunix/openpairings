defmodule PairingsEngineWeb.Components.ManualLink do
  @moduledoc """
  The small "?" beside a page's title that opens the manual at the section
  describing that page. The top bar's Help link opens the matching chapter;
  this one goes straight to the section. Both open a new tab, so the page
  you were asking about is still there when you have read the answer.

  The targets are a closed list (`targets/0`), so a test can check that each
  one still points at a chapter and a heading that exist: a heading renamed
  in `priv/manual/` would otherwise turn these into links to the top of a
  chapter without anyone noticing.
  """
  use Phoenix.Component
  use Gettext, backend: PairingsEngineWeb.Gettext

  import PairingsEngineWeb.CoreComponents, only: [icon: 1]

  @targets %{
    pairings: {"pairing", "the-pairings-page"},
    players: {"players-and-ratings", "the-players-page"},
    standings: {"standings-and-tiebreaks", "the-standings-page"},
    fide_settings: {"fide-mode", "the-fide-page-of-the-settings"},
    trf_import: {"import-export", "trf-file"},
    trf_export: {"fide-report", "the-export-page"},
    teams: {"teams", "setting-up"}
  }

  @doc "Every topic, as `topic => {chapter slug, heading id}`."
  def targets, do: @targets

  @doc "The manual address of `topic`."
  def path(topic) do
    {chapter, anchor} = Map.fetch!(@targets, topic)
    "/help/" <> chapter <> "#" <> anchor
  end

  attr :topic, :atom, required: true, values: Map.keys(@targets)

  def manual_link(assigns) do
    assigns = assign(assigns, :path, path(assigns.topic))

    ~H"""
    <.link
      href={@path}
      target="_blank"
      rel="noopener"
      id={"manual-link-#{@topic}"}
      class="manual-help-link"
      aria-label={gettext("Open the manual for this page")}
      title={gettext("Open the manual for this page")}
    >
      <.icon name="hero-question-mark-circle" class="size-5" />
    </.link>
    """
  end
end
