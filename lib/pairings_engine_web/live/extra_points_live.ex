defmodule PairingsEngineWeb.ExtraPointsLive do
  @moduledoc """
  The "Extra points" settings page (`/t/:id/settings/extra-points`) - SWAR
  parity #12 ("XtPts"): administrative bonus points added to a player's
  standing, optionally auto-assigned from Elo bands. Split out of the
  combined Categories page into its own focused Settings sub-page.
  """
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport

  alias PairingsEngine.{Audit, Tournaments}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    {:ok,
     assign(socket,
       tournament: tournament,
       page_title: "#{tournament.name} · Extra points",
       extra_points_error: nil,
       extra_points_note: nil
     )}
  end

  @impl true
  def handle_info({:tournament_changed, _id, _hint}, socket) do
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
  def handle_event("save_extra_points", %{"tournament" => params}, socket) do
    params = Map.take(params, ["count_extra_points", "extra_points_bands"])
    base = socket.assigns.tournament

    case Tournaments.update_tournament(base, params) do
      {:ok, tournament} ->
        if base.count_extra_points != tournament.count_extra_points or
             base.extra_points_bands != tournament.extra_points_bands do
          Audit.log(
            tournament.id,
            socket.assigns.current_scope,
            "tournament.settings_updated",
            %{
              changed_fields:
                %{}
                |> maybe_change(
                  "count_extra_points",
                  base.count_extra_points,
                  tournament.count_extra_points
                )
                |> maybe_change(
                  "extra_points_bands",
                  base.extra_points_bands,
                  tournament.extra_points_bands
                )
            }
          )
        end

        {:noreply,
         assign(socket, tournament: tournament, extra_points_error: nil, extra_points_note: nil)}

      {:error, changeset} ->
        {:noreply, assign(socket, extra_points_error: error_text(changeset))}
    end
  end

  def handle_event("apply_extra_points_bands", _params, socket) do
    case Tournaments.apply_extra_points_bands(socket.assigns.tournament) do
      {:ok, %{matched: matched, total: total}} ->
        Audit.log(
          socket.assigns.tournament.id,
          socket.assigns.current_scope,
          "standings.extra_points_applied",
          %{matched: matched, total: total}
        )

        {:noreply,
         assign(socket,
           extra_points_note: "Set extra points for #{matched} of #{total} players.",
           extra_points_error: nil
         )}

      {:error, :invalid_bands} ->
        {:noreply,
         assign(socket,
           extra_points_error:
             "Fix the Elo bands field before applying it (e.g. \"1400:1, 1600:0.5\").",
           extra_points_note: nil
         )}

      {:error, changeset} ->
        {:noreply,
         assign(socket, extra_points_error: error_text(changeset), extra_points_note: nil)}
    end
  end

  defp maybe_change(map, _key, same, same), do: map
  defp maybe_change(map, key, before, after_value), do: Map.put(map, key, [before, after_value])

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
          <p class="subtitle" style="margin: 0">{gettext("Settings - Extra points")}</p>
        </div>
      </div>

      <.settings_subnav tournament={@tournament} active={:extra_points} />

      <div class="card">
        <h2>{gettext("Extra points")}</h2>
        <p class="hint" style="margin-top: 0">
          <.rich_text text={
            gettext(
              "Administrative bonus points (SWAR \"XtPts\") - e.g. a handicap head start for lower-rated players. Off by default: pairing and TRF export always use game points only, and standings only add extra points to the ranking once you turn this on. See %[players] to edit a single player's value, or auto-assign everyone from Elo bands below."
            )
          }>
            <:part name="players">
              <.link navigate={~p"/t/#{@tournament.id}/players"}>{gettext("Players")}</.link>
            </:part>
          </.rich_text>
        </p>
        <form id="extra-points-form" phx-submit="save_extra_points">
          <.setting_group>
            <.setting_toggle
              name="tournament[count_extra_points]"
              label={gettext("Count extra points in standings")}
              checked={@tournament.count_extra_points}
            />

            <.setting_field
              label={gettext("Elo bands (rating:bonus, comma-separated)")}
              hint={
                ~s|A player matches the lowest band whose threshold their rating is below (e.g. "1400:1, 1600:0.5" gives 1.0 below 1400, 0.5 from 1400 up to 1599, nothing from 1600 up). Unrated players only match an explicit "0:bonus" band.|
              }
            >
              <input
                type="text"
                name="tournament[extra_points_bands]"
                value={@tournament.extra_points_bands}
                placeholder="e.g. 1400:1, 1600:0.5"
              />
            </.setting_field>
          </.setting_group>
          <p :if={@extra_points_error} class="error-note">{@extra_points_error}</p>
          <p :if={@extra_points_note} class="ok-note">{@extra_points_note}</p>
          <div class="actions">
            <button type="submit" class="pe-btn primary">{gettext("Save extra points settings")}</button>
            <button type="button" class="pe-btn" phx-click="apply_extra_points_bands">
              {gettext("Apply bands to players")}
            </button>
          </div>
        </form>
        <p class="hint" style="margin-bottom: 0">
          {gettext(
            "OpenPairings only supports extra points as an Elo-band bonus added to a player's standing, as configured above. SWAR's other use of extra points - \"speed up pairings\" (accelerating/seeding early-round pairings based on extra points) - is not supported."
          )}
        </p>
      </div>
    </Layouts.app>
    """
  end
end
