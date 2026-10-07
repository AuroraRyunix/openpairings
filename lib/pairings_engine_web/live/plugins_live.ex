defmodule PairingsEngineWeb.PluginsLive do
  @moduledoc """
  "Installed plug-ins" (`/plugins`): every plugin compiled into this build,
  with its version and what it does, and a way into each. The same list as
  the home screen's "Plug-ins" menu (`PairingsEngine.Plugins.installed/0`).

  Routed only in a build with a plugin (`PairingsEngine.Plugins.routes/1`):
  without one there is nothing to list, so there is no page.
  """
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.Plugins

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: gettext("Installed plug-ins"),
       plugins: Plugins.installed()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      publish_status={assigns[:publish_status]}
      update_notice={assigns[:update_notice]}
      flash={@flash}
      current_path={assigns[:current_path]}
      current_scope={@current_scope}
      active="plugins"
    >
      <div class="page-header">
        <div>
          <h1>{gettext("Installed plug-ins")}</h1>
          <p class="subtitle" style="margin: 0">
            {gettext(
              "Parts of this installation that are not in the published application: built in with it, and updated with it."
            )}
          </p>
        </div>
      </div>

      <div id="installed-plugins" class="plugin-cards">
        <section :for={plugin <- @plugins} id={"plugin-#{plugin.id}"} class="card plugin-card">
          <h2>
            {plugin.name} <span class="badge muted">{plugin.version}</span>
          </h2>
          <p>{plugin.description}</p>
          <div class="actions">
            <.link href={plugin.path} id={"open-plugin-#{plugin.id}"} class="pe-btn primary">
              {gettext("Open %{name}", name: plugin.name)}
            </.link>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
