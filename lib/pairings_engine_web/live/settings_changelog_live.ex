defmodule PairingsEngineWeb.SettingsChangelogLive do
  @moduledoc """
  The "Changelog" settings page (`/t/:id/settings/changelog`) — renders
  `CHANGELOG.md` from the repo root, so there is exactly one place that
  gets edited on release (the file itself; see its own header for the
  format and update convention) rather than two copies drifting apart.

  Read and rendered to HTML at COMPILE time, via `@external_resource` —
  not `:code.priv_dir/1`, which points inside `priv/` and has no
  reliable path back out to the repo root once a release has moved
  things around (checked against how this codebase already reaches its
  OTHER root-adjacent asset, `javafo.jar` — that one lives INSIDE
  `priv/`, `lib/pairings_engine/pairing.ex`'s own `Path.join(:code.priv_dir(...),
  "javafo/javafo.jar")`, precisely because `priv/` is the one directory
  guaranteed to ship with any OTP release; `CHANGELOG.md` at the repo
  root is not). `@external_resource` bakes the file's CONTENT into the
  compiled module at build time instead, which sidesteps needing a
  reliable runtime path at all — the tradeoff is that editing
  `CHANGELOG.md` needs a rebuild to show up, same as every other code
  change in a compiled release.
  """
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport

  alias PairingsEngine.Tournaments

  @changelog_path Path.expand("../../../CHANGELOG.md", __DIR__)
  @external_resource @changelog_path

  @changelog_html (case File.read(@changelog_path) do
                     {:ok, markdown} ->
                       case Earmark.as_html(markdown) do
                         {:ok, html, _messages} -> html
                         {:error, _html, _messages} -> "<p>Could not render the changelog.</p>"
                       end

                     {:error, _reason} ->
                       "<p>CHANGELOG.md was not found at compile time.</p>"
                   end)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    {:ok,
     assign(socket,
       tournament: tournament,
       page_title: "#{tournament.name} · Settings · Changelog",
       changelog_html: @changelog_html
     )}
  end

  @impl true
  def handle_info({:tournament_changed, _tournament_id, _hint}, socket) do
    case Tournaments.get_authorized_tournament(
           socket.assigns.current_scope,
           socket.assigns.tournament.id
         ) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "This tournament was deleted.")
         |> push_navigate(to: ~p"/")}

      tournament ->
        {:noreply, assign(socket, tournament: tournament)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      tournament={@tournament}
      active="settings"
    >
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">Settings - Changelog</p>
        </div>
      </div>

      <.settings_subnav tournament={@tournament} active={:changelog} />

      <div class="card changelog-body">
        {raw(@changelog_html)}
      </div>
    </Layouts.app>
    """
  end
end
