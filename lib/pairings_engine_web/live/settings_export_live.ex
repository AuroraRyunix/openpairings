defmodule PairingsEngineWeb.SettingsExportLive do
  @moduledoc """
  The "Export / backup" settings page (`/t/:id/settings/export`) - the full
  JSON backup, the experimental `.swar` export, and the warning that the
  backup carries this tournament's publishing key.

  Split out from `PairingsEngineWeb.SettingsTournamentLive` on 2026-08-29:
  the card had nothing to do with tournament identity, it was just the last
  thing on that page. It gets its own tab for the same reason Results site
  and every other subject in Settings did.
  """
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport

  alias PairingsEngine.{Publishing, Tournaments}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    {:ok,
     assign(socket,
       tournament: tournament,
       page_title: "#{tournament.name} · Settings · Export"
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
      publish_status={assigns[:publish_status]}
      flash={@flash}
      current_path={assigns[:current_path]}
      current_scope={@current_scope}
      tournament={@tournament}
      active="settings"
    >
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">{gettext("Settings - Export")}</p>
        </div>
        <span class={["badge", @tournament.status == "setup" && "muted"]}>{@tournament.status}</span>
      </div>

      <.settings_subnav tournament={@tournament} active={:export} />

      <div class="card">
        <h2>{gettext("Export / backup")}</h2>

        <p class="hint" style="margin-top: 0">
          <.rich_text text={
            gettext(
              "A full JSON backup of this tournament - settings, officials, every player (including norm data), rounds, pairings/results, byes and forbidden pairings. Re-importing it (from the %[tournaments] page) always creates a brand-new tournament, never overwrites this one. For a FIDE-report-shaped TRF16 file instead, see %[pairings]."
            )
          }>
            <:part name="tournaments">
              <.link navigate={~p"/"}>{gettext("Tournaments")}</.link>
            </:part>
            <:part name="pairings">
              <.link navigate={~p"/t/#{@tournament.id}/pairings"}>{gettext("Pairings")}</.link>
            </:part>
          </.rich_text>
          <span :if={@tournament.manual_ranking}>
            {gettext(
              "Note that its rank column is the computed order, not manual ranking's hand-set one."
            )}
          </span>
        </p>

        <%!-- Shown only when the file would actually carry the key, so that
              the warning is never noise and is always true when it appears.
              It says what the key can DO rather than that the file is
              "sensitive" - a backup of a chess tournament reads as harmless,
              and the reason to guard this one is not obvious from the
              outside. --%>
        <p :if={Publishing.published?(@tournament)} class="hint" style="color: var(--danger)">
          {gettext(
            "This backup carries this tournament's publishing key. Anyone who has the file can update its page on the results site, or delete that page along with its whole history and any entries collected for it. That is deliberate - it is how a rebuilt machine recovers control of what it published - but treat the file like a password."
          )}
        </p>

        <div class="actions">
          <a class="pe-btn" href={~p"/t/#{@tournament.id}/export/json"} target="_blank">
            {gettext("Export full backup (JSON)")}
          </a>

          <a
            class="pe-btn"
            href={~p"/t/#{@tournament.id}/export/swar"}
            target="_blank"
            title={
              gettext(
                "A .swar file SWAR itself can open - never verified against a real SWAR install, see docs/swar-import.md"
              )
            }
          >
            {gettext("Export .swar (v7, experimental)")}
          </a>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
