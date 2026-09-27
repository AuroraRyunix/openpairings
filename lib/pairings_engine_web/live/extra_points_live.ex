defmodule PairingsEngineWeb.ExtraPointsLive do
  @moduledoc """
  The "Extra points" settings page (`/t/:id/settings/extra-points`) - SWAR
  parity #12 ("XtPts"): points a player holds on top of their game points,
  optionally auto-assigned from Elo bands. Split out of the combined
  Categories page into its own focused Settings sub-page.

  Two kinds, chosen with `extra_points_mode` (docs/extra-points.md): a
  **handicap** - a head start, counted in the standings and in the pairing
  score while "count" is on - and an **acceleration** - SWAR's XtraPoints,
  always handed to the pairing engine as virtual points, kept in the final
  standings or not as the organiser chooses. The bands read "below the
  rating" for one and "at or above" for the other, and the page's wording
  follows the mode picked in the form before it is saved.
  """
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport

  alias PairingsEngine.{Audit, Tournaments}
  alias PairingsEngine.Tournaments.Tournament

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    {:ok,
     assign(socket,
       tournament: tournament,
       mode: tournament.extra_points_mode,
       count: tournament.count_extra_points == true,
       page_title: "#{tournament.name} · Extra points",
       extra_points_error: nil,
       extra_points_note: nil,
       reduce_error: nil,
       reduce_note: nil
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
  # The mode picked but not yet saved: the toggle's label, the band hint
  # and the example all follow it, so the arbiter reads what the choice
  # means before committing to it - the not-FIDE warning too, which follows
  # the counting switch as well.
  def handle_event("change_extra_points", %{"tournament" => params}, socket) do
    mode = if params["extra_points_mode"] == "acceleration", do: "acceleration", else: "handicap"
    {:noreply, assign(socket, mode: mode, count: params["count_extra_points"] == "true")}
  end

  def handle_event("save_extra_points", %{"tournament" => params}, socket) do
    params = Map.take(params, ["extra_points_mode", "count_extra_points", "extra_points_bands"])
    base = socket.assigns.tournament

    case Tournaments.update_tournament(base, params) do
      {:ok, tournament} ->
        changed =
          ~w(extra_points_mode count_extra_points extra_points_bands)a
          |> Enum.reduce(%{}, fn field, acc ->
            maybe_change(acc, to_string(field), Map.get(base, field), Map.get(tournament, field))
          end)

        if changed != %{} do
          Audit.log(
            tournament.id,
            socket.assigns.current_scope,
            "tournament.settings_updated",
            %{changed_fields: changed}
          )
        end

        {:noreply,
         assign(socket,
           tournament: tournament,
           mode: tournament.extra_points_mode,
           count: tournament.count_extra_points == true,
           extra_points_error: nil,
           extra_points_note: nil
         )}

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
           extra_points_note:
             ngettext(
               "Set extra points for %{matched} of %{count} player.",
               "Set extra points for %{matched} of %{count} players.",
               total,
               matched: matched
             ),
           extra_points_error: nil
         )}

      {:error, :invalid_bands} ->
        {:noreply,
         assign(socket,
           extra_points_error:
             gettext("Fix the Elo bands field before applying it (e.g. \"1400:1, 1600:0.5\")."),
           extra_points_note: nil
         )}

      {:error, changeset} ->
        {:noreply,
         assign(socket, extra_points_error: error_text(changeset), extra_points_note: nil)}
    end
  end

  def handle_event("reduce_extra_points", %{"reduce" => params}, socket) do
    tournament = socket.assigns.tournament

    with {:ok, from} <- parse_rating(params["from"]),
         {:ok, to} <- parse_rating(params["to"]),
         {:ok, %{changed: changed}} <- Tournaments.reduce_extra_points(tournament, from, to) do
      Audit.log(
        tournament.id,
        socket.assigns.current_scope,
        "standings.extra_points_reduced",
        %{changed: changed, from: from, to: to, amount: 0.5}
      )

      {:noreply,
       assign(socket,
         reduce_error: nil,
         reduce_note:
           ngettext(
             "Took half a point off %{count} player.",
             "Took half a point off %{count} players.",
             changed
           )
       )}
    else
      {:error, :invalid_range} ->
        {:noreply,
         assign(socket,
           reduce_error:
             gettext("Give a rating range whose first number is not above the second."),
           reduce_note: nil
         )}

      {:error, reason} ->
        {:noreply, assign(socket, reduce_error: error_text(reason), reduce_note: nil)}
    end
  end

  defp parse_rating(value) do
    case Integer.parse(String.trim(value || "")) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, :invalid_range}
    end
  end

  defp maybe_change(map, _key, same, same), do: map
  defp maybe_change(map, key, before, after_value), do: Map.put(map, key, [before, after_value])

  @impl true
  def render(assigns) do
    # Whether the choice in the form puts extra points in the pairing
    # (`Tournament.extra_points_pairing?/1`): what the warning below is about.
    pairing? =
      Tournament.extra_points_pairing?(%{
        assigns.tournament
        | extra_points_mode: assigns.mode,
          count_extra_points: assigns.count
      })

    assigns = assign(assigns, acceleration?: assigns.mode == "acceleration", pairing?: pairing?)

    ~H"""
    <Layouts.app
      publish_status={assigns[:publish_status]}
      update_notice={assigns[:update_notice]}
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
              "Points a player holds on top of their game points (SWAR \"XtPts\"). Choose what they are for below. See %[players] to edit a single player's value, or assign everyone's from Elo bands."
            )
          }>
            <:part name="players">
              <.link navigate={~p"/t/#{@tournament.id}/players"}>{gettext("Players")}</.link>
            </:part>
          </.rich_text>
        </p>
        <form
          id="extra-points-form"
          phx-change="change_extra_points"
          phx-submit="save_extra_points"
        >
          <.setting_group>
            <.setting_field label={gettext("Kind of extra points")}>
              <select name="tournament[extra_points_mode]" id="extra-points-mode">
                <option value="handicap" selected={not @acceleration?}>
                  {gettext("Handicap - a head start for players below a rating")}
                </option>
                <option value="acceleration" selected={@acceleration?}>
                  {gettext("Acceleration - SWAR's extra points, for players at or above a rating")}
                </option>
              </select>
            </.setting_field>

            <p :if={not @acceleration?} id="extra-points-mode-hint" class="hint">
              {gettext(
                "Handicap: the extra points are a head start. With counting on they are added to the player's score everywhere - the standings rank on points plus extra points, and the pairing puts players in score groups by the same total, so the leader on handicap meets the players chasing them. With counting off they do nothing. The FIDE TRF report keeps game points only; the extra points go in its 299 records."
              )}
            </p>
            <p :if={@acceleration?} id="extra-points-mode-hint" class="hint">
              {gettext(
                "Acceleration (SWAR's XtraPoints): the extra points are virtual points for pairing. Every round, the pairing engine adds them to the player's score when it builds the score groups, so the strongest players meet each other from round 1. Take them off part-way with \"Remove half a point\" below; rounds already paired keep what they were paired with. Whether they also count in the standings is the switch below - on, as SWAR does; off, like Baku acceleration, the final standings are game points only."
              )}
            </p>

            <%!-- One column, two meanings: "these points count in the
                  standings". In handicap mode that also puts them in the
                  pairing; in acceleration mode the pairing has them anyway. --%>
            <.setting_toggle
              name="tournament[count_extra_points]"
              label={
                if(@acceleration?,
                  do: gettext("Keep acceleration points in the final standings"),
                  else: gettext("Count extra points (standings and pairing)")
                )
              }
              checked={@count}
            />

            <.setting_field
              label={gettext("Elo bands (rating:bonus, comma-separated)")}
              hint={band_hint(@acceleration?)}
            >
              <input
                type="text"
                id="extra-points-bands"
                name="tournament[extra_points_bands]"
                value={@tournament.extra_points_bands}
                placeholder={
                  if(@acceleration?, do: "e.g. 1800:0.5, 2000:1", else: "e.g. 1400:1, 1600:0.5")
                }
              />
            </.setting_field>
          </.setting_group>

          <%!-- The same warning the bye exclusion gives on the player form:
                extra points in the pairing are not FIDE's (Baku is, and
                cannot be on with them). The pairing records the first round
                they reach the engine - `Pairing.pairing_deviations/2`. --%>
          <div :if={@pairing?} id="extra-points-fide-warning" class="pe-modal-warn" role="note">
            <strong>{gettext("Not part of the FIDE rules.")}</strong>
            {gettext(
              "With extra points in the pairing, the Swiss pairings will differ from what the FIDE rules pair, and a FIDE checker cannot replay the rounds they change. The first round paired while a player holds extra points is recorded as the round the tournament stopped matching the FIDE rules, and the audit trail records it. With nobody holding extra points, nothing changes."
            )}
            <p
              :if={@tournament.fide_homologated}
              id="extra-points-fide-homologated-warning"
              style="margin: 6px 0 0"
            >
              <strong>{gettext("This tournament is FIDE-homologated.")}</strong>
              {gettext(
                "Its FIDE record will say it stopped matching the FIDE rules from that round on. Only use extra points in the pairing if the rating officer has agreed."
              )}
            </p>
          </div>

          <p :if={@extra_points_error} class="error-note">{@extra_points_error}</p>
          <p :if={@extra_points_note} class="ok-note">{@extra_points_note}</p>
          <div class="actions">
            <button type="submit" class="pe-btn primary">{gettext("Save extra points settings")}</button>
            <button
              type="button"
              id="apply-extra-points-bands"
              class="pe-btn"
              phx-click="apply_extra_points_bands"
            >
              {gettext("Apply bands to players")}
            </button>
          </div>
        </form>
        <p :if={@tournament.extra_points_mode != @mode} class="hint" style="margin-bottom: 0">
          {gettext(
            "Save first: \"Apply bands to players\" uses the saved kind and bands, not the ones in the form."
          )}
        </p>
      </div>

      <div :if={Tournament.extra_points_acceleration?(@tournament)} class="card">
        <h2>{gettext("Remove half a point")}</h2>
        <p class="hint" style="margin-top: 0">
          {gettext(
            "Winds the acceleration down, as SWAR's \"Remove\" does: every player rated in the range who still has extra points loses half a point, never going below zero. The next round is paired with what is left; rounds already paired are not changed."
          )}
        </p>
        <form id="reduce-extra-points-form" phx-submit="reduce_extra_points">
          <.setting_group>
            <.setting_field label={gettext("From rating")}>
              <input type="number" min="0" name="reduce[from]" value="0" />
            </.setting_field>
            <.setting_field label={gettext("To rating")}>
              <input type="number" min="0" name="reduce[to]" value="3000" />
            </.setting_field>
          </.setting_group>
          <p :if={@reduce_error} class="error-note">{@reduce_error}</p>
          <p :if={@reduce_note} class="ok-note">{@reduce_note}</p>
          <div class="actions">
            <button type="submit" class="pe-btn">{gettext("Remove half a point")}</button>
          </div>
        </form>
      </div>
    </Layouts.app>
    """
  end

  defp band_hint(true),
    do:
      gettext(
        "A player gets the band with the highest rating at or below their own, as in SWAR (e.g. \"1800:0.5, 2000:1\" gives 1.0 from 2000 up, 0.5 from 1800 up to 1999, nothing below 1800). A \"0:bonus\" band is everyone else, unrated players included."
      )

  defp band_hint(false),
    do:
      gettext(
        "A player matches the lowest band whose threshold their rating is below (e.g. \"1400:1, 1600:0.5\" gives 1.0 below 1400, 0.5 from 1400 up to 1599, nothing from 1600 up). Unrated players only match an explicit \"0:bonus\" band."
      )
end
