defmodule PairingsEngineWeb.ChangelogLive do
  @moduledoc """
  The app-wide "Changelog" page (`/changelog`) - renders `CHANGELOG.md`
  from the repo root via `PairingsEngine.Changelog`. Not tournament-scoped
  (the changelog describes the whole app, not one tournament), so it sits
  in the main nav alongside Tournaments/Tools rather than buried inside a
  specific tournament's Settings, which is where it used to live
  (`SettingsChangelogLive`, now a redirect here for old links).
  """
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.Changelog

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Changelog", changelog_html: Changelog.html())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      publish_status={assigns[:publish_status]}
      flash={@flash}
      current_path={assigns[:current_path]}
      current_scope={@current_scope}
      active="changelog"
    >
      <div class="page-header">
        <div>
          <h1>{gettext("Changelog")}</h1>
          <p class="subtitle" style="margin: 0">
            {gettext("What's changed in OpenPairings, release by release")}
          </p>
        </div>
      </div>

      <div class="card changelog-body">
        {raw(@changelog_html)}
      </div>
    </Layouts.app>
    """
  end
end
