defmodule PairingsEngineWeb.PostponedLive do
  @moduledoc """
  The Postponed games page (`/t/:id/postponed`), there when the tournament
  allows postponed games (Settings, Scoring).

  Every game that was ever postponed, open or played, what it counts as
  while it waits, when it was played, and what has been sent of it: in its
  round's report (with its result, or as `?` if it was still open when that
  report was marked as sent) or in a postponed-games file. And that file
  itself - the games sent as `?` and played since, packed into as few extra
  rounds as possible with nobody playing twice in a round - with the same
  "finalise results for TRF sending" box as the main report, so each game
  is sent exactly once. See `PairingsEngine.PostponedGames`.
  """
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.{PostponedGames, Results, Tournaments}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    {:ok,
     socket
     |> assign(tournament: tournament, page_title: "#{tournament.name} · Postponed games")
     |> load()}
  end

  @impl true
  def handle_info({:tournament_changed, _id, _hint}, socket) do
    case Tournaments.get_authorized_tournament(
           socket.assigns.current_scope,
           socket.assigns.tournament.id
         ) do
      nil -> {:noreply, push_navigate(socket, to: ~p"/")}
      tournament -> {:noreply, socket |> assign(tournament: tournament) |> load()}
    end
  end

  defp load(socket) do
    t = socket.assigns.tournament
    sendable = PostponedGames.sendable_late_games(t)

    assign(socket,
      games: PostponedGames.all_games(t),
      sendable: sendable,
      packed: sendable |> Enum.map(& &1.pairing) |> PostponedGames.pack()
    )
  end

  @impl true
  def handle_event("set_played_on", %{"pairing-id" => id, "played_on" => date}, socket) do
    with %{pairing: pairing} <-
           Enum.find(socket.assigns.games, &(to_string(&1.pairing.id) == id)),
         {:ok, date} <- Date.from_iso8601(date),
         {:ok, _} <- Tournaments.set_played_on(pairing, date) do
      {:noreply, socket |> put_flash(:info, gettext("Date saved.")) |> load()}
    else
      {:error, :already_sent} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Not changed: this game was already sent in a postponed-games file.")
         )}

      {:error, reason} when is_atom(reason) ->
        {:noreply,
         put_flash(socket, :error, PairingsEngineWeb.SettingsSupport.error_text(reason))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("That is not a date."))}
    end
  end

  defp player_name(nil), do: "-"
  defp player_name(player), do: player.name

  # From `postponed_by`, which outlives the `*W`/`*B` the result carried.
  defp postponed_by_text(%{postponed_by: "white"}), do: gettext("White")
  defp postponed_by_text(%{postponed_by: "black"}), do: gettext("Black")
  defp postponed_by_text(_pairing), do: gettext("nobody named")

  defp outcome_text("win"), do: gettext("a win")
  defp outcome_text("loss"), do: gettext("a loss")
  defp outcome_text(_draw), do: gettext("a draw")

  defp status_text(pairing) do
    cond do
      Results.postponed?(pairing.result) ->
        gettext("still to be played")

      pairing.played_on ->
        gettext("played on %{date}: %{result}",
          date: Date.to_iso8601(pairing.played_on),
          result: pairing.result
        )

      true ->
        gettext("played: %{result}", result: pairing.result)
    end
  end

  defp sent_text(pairing) do
    cond do
      pairing.postponed_reported_at ->
        gettext("sent in a postponed-games file on %{date}",
          date: pairing.postponed_reported_at |> DateTime.to_date() |> Date.to_iso8601()
        )

      pairing.finalised_open and Results.postponed?(pairing.result) ->
        gettext("in its round's report as ? - its result goes in the postponed-games file")

      pairing.finalised_open ->
        gettext("in its round's report as ? - ready for the postponed-games file")

      pairing.finalised_at ->
        gettext("sent in its round's report, with its result")

      true ->
        gettext("not sent yet - goes in its round's report")
    end
  end

  defp round_date(games) do
    case games |> Enum.map(& &1.played_on) |> Enum.reject(&is_nil/1) do
      [] -> "-"
      dates -> dates |> Enum.max(Date) |> Date.to_iso8601()
    end
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
      tournament={@tournament}
      active="pairings"
    >
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">{gettext("Postponed games")}</p>
        </div>

        <div class="actions" style="margin: 0">
          <.link class="pe-btn" navigate={~p"/t/#{@tournament.id}/pairings"}>
            {gettext("Pairings & results")}
          </.link>
        </div>
      </div>

      <div :if={!@tournament.postponed_games} id="postponed-off" class="card">
        <p>
          {gettext("This tournament does not allow postponed games.")}
          <.link navigate={~p"/t/#{@tournament.id}/settings/scoring"}>
            {gettext("Turn them on under Settings, Scoring.")}
          </.link>
        </p>
      </div>

      <div class="card table-card" id="postponed-list">
        <table class="pe-table">
          <thead>
            <tr>
              <th class="num">{gettext("Round")}</th>
              <th class="num">{gettext("Board")}</th>
              <th>{gettext("White")}</th>
              <th>{gettext("Black")}</th>
              <th>{gettext("Postponed by")}</th>
              <th>{gettext("Counts as (White - Black)")}</th>
              <th>{gettext("Status")}</th>
              <th>{gettext("Sent")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@games == []}>
              <td colspan="8" class="empty">{gettext("No game has been postponed yet.")}</td>
            </tr>
            <tr :for={%{round: round, pairing: p} <- @games} id={"postponed-row-#{p.id}"}>
              <td class="num">{round}</td>
              <td class="num">{p.display_board || p.board}</td>
              <td>{player_name(p.white_player)}</td>
              <td>{player_name(p.black_player)}</td>
              <td>{postponed_by_text(p)}</td>
              <td>{outcome_text(p.provisional_white)} - {outcome_text(p.provisional_black)}</td>
              <td>
                {status_text(p)}
                <form
                  :if={!Results.postponed?(p.result) and is_nil(p.postponed_reported_at)}
                  id={"played-on-form-#{p.id}"}
                  phx-submit="set_played_on"
                  style="display: inline-flex; gap: 4px; margin-left: 6px"
                >
                  <input type="hidden" name="pairing-id" value={p.id} />
                  <input
                    type="date"
                    name="played_on"
                    value={p.played_on && Date.to_iso8601(p.played_on)}
                    aria-label={gettext("Date played")}
                  />
                  <button type="submit" class="pe-btn">{gettext("Save date")}</button>
                </form>
              </td>
              <td>{sent_text(p)}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="card" id="postponed-trf">
        <h2>{gettext("Postponed-games TRF")}</h2>
        <p class="subtitle" style="margin: 0 0 8px">
          {gettext(
            "Games that were still open when their round's report was sent went out as ? in it, and that report is never changed. Once played, they go in this file instead - as extra rounds, as few as possible, with nobody playing twice in a round - so each game is sent exactly once."
          )}
        </p>

        <p :if={@sendable == []} id="postponed-trf-empty" class="hint">
          {gettext("Nothing to send: no postponed game was played after its round was sent.")}
        </p>

        <div :if={@sendable != []}>
          <ol id="postponed-trf-rounds">
            <li :for={{games, i} <- Enum.with_index(@packed, 1)} id={"postponed-trf-round-#{i}"}>
              {gettext("Extra round %{n} (%{date}):", n: i, date: round_date(games))}
              {Enum.map_join(games, "; ", fn p ->
                "#{player_name(p.white_player)} - #{player_name(p.black_player)} #{p.result}"
              end)}
            </li>
          </ol>

          <.form
            for={%{}}
            id="postponed-trf-form"
            action={~p"/t/#{@tournament.id}/export/postponed-trf"}
            method="post"
          >
            <label class="field-check">
              <input type="hidden" name="finalise" value="false" />
              <input type="checkbox" name="finalise" value="true" id="postponed-trf-finalise" />
              {gettext("Finalise results for TRF sending - these games will not be sent again")}
            </label>
            <button type="submit" class="pe-btn primary">
              {gettext("Download postponed-games TRF")}
            </button>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
