defmodule PairingsEngineWeb.LiveRoundLive do
  @moduledoc """
  Read-only "projector" view of a tournament's latest paired round: the
  pairing list with live results, and current standings below it. Also the
  arbiter's mobile-enrollment QR generator (see PairingsEngine.Mobile) - both
  live here since an arbiter typically opens this page once and leaves it up.
  Meant to be popped into its own tab/window (see the "Live view & phone QR"
  link on PairingsLive) and left open - it subscribes to the same tournament
  topic as every other tournament-scoped view and updates the instant a
  result is entered elsewhere, no polling.
  """

  use PairingsEngineWeb, :live_view

  alias PairingsEngine.{Tournaments, Standings, Tiebreaks, Keizer, Mobile, PairingDisplay}
  alias PairingsEngine.Pairing, as: Engine

  @result_labels %{
    "1-0" => "1-0",
    "1/2-1/2" => "½-½",
    "0-1" => "0-1",
    "1/2-0" => "½-0",
    "0-1/2" => "0-½",
    "1-0FF" => "1-0 FF",
    "0-1FF" => "0-1 FF",
    "0-0FF" => "0-0 FF",
    "0-0" => "0-0"
  }

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    {:ok,
     socket
     |> assign(
       tournament: tournament,
       page_title: "#{tournament.name} · Live",
       new_enrollment: nil
     )
     |> assign_enrollments()
     |> reload()}
  end

  defp assign_enrollments(socket) do
    assign(socket, :enrollments, Mobile.list_enrollments(socket.assigns.tournament.id))
  end

  defp enroll_expiry(%DateTime{} = dt), do: Calendar.strftime(dt, "%d %b %H:%M")

  @impl true
  def handle_event("generate_enrollment", _params, socket) do
    {:ok, enrollment} = Mobile.create_enrollment(socket.assigns.tournament.id)

    {:noreply,
     socket
     |> assign(new_enrollment: enrollment)
     |> assign_enrollments()}
  end

  def handle_event("revoke_enrollment", %{"id" => id}, socket) do
    case Integer.parse(to_string(id)) do
      {int, _} -> Mobile.revoke(socket.assigns.tournament.id, int)
      _ -> :ok
    end

    new_enrollment =
      if socket.assigns.new_enrollment &&
           to_string(socket.assigns.new_enrollment.id) == to_string(id),
         do: nil,
         else: socket.assigns.new_enrollment

    {:noreply, socket |> assign(new_enrollment: new_enrollment) |> assign_enrollments()}
  end

  # Purely a display page - nothing here is user-editable, so every
  # broadcast just reloads everything.
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
        {:noreply, socket |> assign(tournament: tournament) |> reload()}
    end
  end

  # Keizer tournaments show their own ladder (rank/value/Keizer points)
  # instead of the FIDE-tiebreak table - see PairingsEngine.Keizer.standings/1
  # and docs/pairing-systems.md, same as StandingsLive/PublicStandingsLive.
  defp reload(socket) do
    tournament = socket.assigns.tournament
    paired = Engine.paired_rounds_count(tournament.id)
    keizer? = tournament.pairing_system == "keizer"

    assign(socket,
      round_number: paired,
      round: paired > 0 && Tournaments.get_round(tournament.id, paired),
      scores:
        if(paired > 0, do: Standings.player_scores_before_round(tournament, paired), else: %{}),
      round_byes:
        if(paired > 0, do: Tournaments.list_byes_for_round(tournament.id, paired), else: []),
      keizer?: keizer?,
      entries:
        if(keizer?, do: Keizer.standings(tournament), else: Standings.standings(tournament))
    )
  end

  defp player_label(nil), do: ""

  defp player_label(player) do
    rating = PairingsEngine.Tournaments.Player.rating(player)

    "#{if player.title != "", do: "#{player.title} "}#{player.name}" <>
      if(rating > 0, do: " (#{rating})", else: "")
  end

  # Board-list label only: `player_label/1` plus the player's score coming
  # into this round, in the same parenthetical - "Name (2400, 2.5)", or
  # "Name (2.5)" with no rating.
  defp seat_label(nil, _scores), do: ""

  defp seat_label(player, scores) do
    rating = PairingsEngine.Tournaments.Player.rating(player)
    score = format_score(Map.get(scores, player.id, 0.0))
    title = if player.title != "", do: "#{player.title} "

    bracket = if rating > 0, do: "(#{rating}, #{score})", else: "(#{score})"

    "#{title}#{player.name} #{bracket}"
  end

  defp format_score(v) when is_float(v) do
    if v == Float.round(v, 0), do: trunc(v), else: v
  end

  defp format_score(v), do: v

  defp result_label(result), do: Map.get(@result_labels, result, result)

  # Same display logic the authenticated Pairings page uses
  # (`PairingsEngineWeb.PairingsLive.display_rows/1`) - fixed-table
  # ("special") boards renumbered/relabeled and moved to the end, byes and
  # vacant seats sorted below those, real boards renumbered to close the
  # gap. Before this, this page just sorted by raw `pairing.board`, so
  # the projector view silently disagreed with the Pairings page (and
  # print) on both the board LABEL and the row ORDER the moment a
  # tournament had a fixed-table player, a bye, or an absence.
  # Hidden rows (an arbiter's "don't show me this fully-vacated board" -
  # see `PairingsEngine.Tournaments.set_pairing_hidden/3`) are filtered out
  # before they ever reach `PairingDisplay`, so a hidden row plays no part
  # in the (already-frozen - see `PairingDisplay`'s moduledoc) board
  # renumbering at all, same as PairingsLive's own `display_rows/1`.
  defp display_rows(pairings) do
    pairings |> Enum.reject(& &1.hidden) |> PairingDisplay.with_display_boards()
  end

  # Label for a byes-table row's `type` - distinct from the "bye" badge
  # shown for a pairing-allocated bye (a real Pairing row), since these
  # never appear in round.pairings (see Tournaments.list_byes_for_round/2).
  defp bye_type_label("requested-half"), do: "requested half-point bye"
  defp bye_type_label("requested-zero"), do: "requested zero-point bye"
  defp bye_type_label("absent"), do: "absent"
  defp bye_type_label(other), do: other

  defp format_tb(value) when is_float(value) do
    if value == Float.round(value, 0), do: trunc(value), else: value
  end

  defp format_tb(value), do: value

  defp tb_name(code), do: (Tiebreaks.get(code) || %{name: code}).name

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} tournament={@tournament} active="live">
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">
            <%= if @round_number > 0 do %>
              {gettext("Live · Round %{n}", n: @round_number)}
            <% else %>
              {gettext("Live · no rounds paired yet")}
            <% end %>
          </p>
        </div>
      </div>

      <details class="card" style="margin-bottom: 20px">
        <summary style="cursor: pointer; font-weight: 650">
          {gettext("📱 Enrol a phone to enter results")}
        </summary>

        <p class="hint">
          {gettext(
            "Let helpers enter results from their phone, no account needed. Show them the QR code or the 6-digit code. Access is result-entry only, scoped to this tournament, and you can revoke it any time."
          )}
        </p>

        <button class="pe-btn primary" phx-click="generate_enrollment">{gettext("Generate a code")}</button>

        <div :if={@new_enrollment} class="enroll-panel" style="margin-top: 16px">
          <div class="enroll-qr">
            <div class="enroll-qr-inner">
              {Phoenix.HTML.raw(Mobile.qr_svg(url(~p"/m/e/#{@new_enrollment.token}")))}
            </div>
          </div>
          <div>
            <div class="enroll-code-label">{gettext("6-digit code")}</div>
            <div class="enroll-code">{@new_enrollment.code}</div>
            <p class="enroll-url">
              <.rich_text text={
                gettext("Scan the QR, or open %[url] on the phone and enter the code.")
              }>
                <:part name="url"><strong>{url(~p"/m")}</strong></:part>
              </.rich_text>
            </p>
            <p class="hint">
              {gettext("Expires %{when}.", when: enroll_expiry(@new_enrollment.expires_at))}
            </p>
          </div>
        </div>

        <div :if={@enrollments != []} style="margin-top: 18px">
          <h3 style="margin: 0 0 8px; font-size: 14px">{gettext("Active phones")}</h3>
          <table class="pe-table">
            <tbody>
              <tr :for={e <- @enrollments}>
                <td><strong>{gettext("Code %{code}", code: e.code)}</strong></td>
                <td class="hint">{gettext("expires %{when}", when: enroll_expiry(e.expires_at))}</td>
                <td style="text-align: right">
                  <button class="pe-btn danger-link" phx-click="revoke_enrollment" phx-value-id={e.id}>
                    {gettext("Revoke")}
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </details>

      <details class="card" style="margin-bottom: 20px">
        <summary style="cursor: pointer; font-weight: 650">
          {gettext("📣 Let spectators follow the standings")}
        </summary>

        <%= if @tournament.public_pages_enabled do %>
          <p class="hint">
            {gettext(
              "Anyone can scan this to open live standings on their own phone - no login needed."
            )}
          </p>
          <div class="enroll-panel" style="margin-top: 16px">
            <div class="enroll-qr">
              <div class="enroll-qr-inner">
                {Phoenix.HTML.raw(Mobile.qr_svg(url(~p"/p/#{@tournament.public_slug}/standings")))}
              </div>
            </div>
            <div>
              <p class="enroll-url">
                <.rich_text text={gettext("Or open %[url]")}>
                  <:part name="url">
                    <strong>{url(~p"/p/#{@tournament.public_slug}/standings")}</strong>
                  </:part>
                </.rich_text>
              </p>
            </div>
          </div>
        <% else %>
          <p class="hint">
            <.rich_text text={
              gettext(
                "Public pages are off for this tournament. %[settings] to get a shareable link and QR code."
              )
            }>
              <:part name="settings">
                <.link navigate={~p"/t/#{@tournament.id}/settings"}>
                  {gettext("Turn them on in Settings")}
                </.link>
              </:part>
            </.rich_text>
          </p>
        <% end %>
      </details>

      <div :if={@round == nil} class="card empty">
        <p><strong>{gettext("No round has been paired yet.")}</strong></p>
      </div>

      <div :if={@round} class="card table-card">
        <table class="pe-table">
          <thead>
            <tr>
              <th class="num">{gettext("Board")}</th>
              <th>{gettext("White")}</th>
              <th style="text-align: center; width: 160px">{gettext("Result")}</th>
              <th>{gettext("Black")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={%{pairing: pairing, board: display_board} <- display_rows(@round.pairings)}>
              <td class="num">{display_board}</td>
              <td><strong>{seat_label(pairing.white_player, @scores)}</strong></td>
              <td style="text-align: center">
                <%= cond do %>
                  <% pairing.result == "bye" -> %>
                    <span class="badge">{gettext("bye (%{pts} pt)", pts: @tournament.bye_value)}</span>
                  <% pairing.result == "" -> %>
                    <span class="badge muted">{gettext("in progress")}</span>
                  <% true -> %>
                    <span class="badge">{result_label(pairing.result)}</span>
                <% end %>
              </td>
              <td>{seat_label(pairing.black_player, @scores)}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@round_byes != []} class="card table-card" style="margin-top: 16px">
        <table class="pe-table">
          <thead>
            <tr>
              <th>{gettext("Player")}</th>
              <th style="text-align: center; width: 220px">Bye</th>
            </tr>
          </thead>

          <tbody>
            <tr :for={bye <- @round_byes}>
              <td>{player_label(bye.player)}</td>

              <td style="text-align: center">
                <span class="badge">
                  {bye_type_label(bye.type)} ({Standings.bye_points_for_row(bye, @tournament)} pt)
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <h2 style="margin-top: 32px">{gettext("Standings")}</h2>

      <div :if={@entries == []} class="card empty">
        <p><strong>{gettext("No players registered yet.")}</strong></p>
      </div>

      <div :if={@entries != [] and !@keizer?} class="card table-card">
        <table class="pe-table">
          <thead>
            <tr>
              <th class="num">{gettext("Rank")}</th>
              <th>{gettext("Name")}</th>
              <th class="num">Elo</th>
              <th class="num">Pts</th>
              <th :for={code <- @tournament.tiebreaks} class="num" title={tb_name(code)}>
                {code}
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :for={entry <- @entries}>
              <td class="num">{entry.rank}</td>
              <td>
                <strong>
                  {if entry.player.title != "", do: "#{entry.player.title} "}{entry.player.name}
                </strong>
              </td>
              <td class="num">
                {if PairingsEngine.Tournaments.Player.rating(entry.player) > 0,
                  do: PairingsEngine.Tournaments.Player.rating(entry.player),
                  else: "-"}
              </td>
              <td class="num"><strong>{entry.points}</strong></td>
              <td :for={code <- @tournament.tiebreaks} class="num">
                {format_tb(Map.get(entry.tiebreaks, code, 0.0))}
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@entries != [] and @keizer?} class="card table-card">
        <table class="pe-table">
          <thead>
            <tr>
              <th class="num">{gettext("Rank")}</th>
              <th>{gettext("Name")}</th>
              <th class="num">Elo</th>
              <th class="num">{gettext("Value")}</th>
              <th class="num">{gettext("Keizer pts")}</th>
              <th class="num">{gettext("Score")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={entry <- @entries}>
              <td class="num">{entry.rank}</td>
              <td>
                <strong>
                  {if entry.player.title != "", do: "#{entry.player.title} "}{entry.player.name}
                </strong>
              </td>
              <td class="num">
                {if PairingsEngine.Tournaments.Player.rating(entry.player) > 0,
                  do: PairingsEngine.Tournaments.Player.rating(entry.player),
                  else: "-"}
              </td>
              <td class="num">{entry.value}</td>
              <td class="num"><strong>{entry.points}</strong></td>
              <td class="num">{entry.raw_points}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end
end
