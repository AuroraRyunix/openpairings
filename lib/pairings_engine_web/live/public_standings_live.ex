defmodule PairingsEngineWeb.PublicStandingsLive do
  @moduledoc """
  Public (no login required) read-only view of a tournament's current
  standings - reachable at `/p/:slug/standings` where `:slug` is the
  tournament's unguessable `public_slug` (see docs/public-pages.md), not
  its numeric id. Anyone holding the link can view it; nothing here is
  editable. Subscribes to the tournament's PubSub topic and reloads live
  when results are entered elsewhere, same as the authenticated pages.
  """

  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.Components.PublicTournamentMeta

  alias PairingsEngine.{Tournaments, Tiebreaks, Standings, Keizer}
  alias PairingsEngine.Tournaments.Player

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    tournament =
      Tournaments.get_tournament_by_public_slug(slug) ||
        raise Ecto.NoResultsError, queryable: Tournaments.Tournament

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    {:ok,
     socket
     |> assign(
       tournament: tournament,
       slug: slug,
       page_title: "#{tournament.name} · Standings",
       gone: false
     )
     |> reload_standings()}
  end

  @impl true
  def handle_info({:tournament_changed, _tournament_id, _hint}, socket) do
    case Tournaments.get_tournament_by_public_slug(socket.assigns.slug) do
      nil -> {:noreply, assign(socket, gone: true)}
      tournament -> {:noreply, socket |> assign(tournament: tournament) |> reload_standings()}
    end
  end

  # Keizer tournaments show their own ladder (rank/value/Keizer points)
  # instead of the FIDE-tiebreak table - see PairingsEngine.Keizer.standings/1
  # and docs/pairing-systems.md, and StandingsLive (the authenticated
  # equivalent of this page), which does the same.
  #
  # Manual ranking (SWAR parity #23) mirrors StandingsLive: applied only on
  # the non-Keizer branch (see docs/manual-standings.md for why Keizer
  # doesn't offer it), read-only here - no reorder controls, just the same
  # banner, since a silent override is exactly as misleading on the public
  # page as anywhere else (arguably more so - this is the page anyone with
  # the link sees, unauthenticated).
  defp reload_standings(socket) do
    tournament = socket.assigns.tournament
    keizer? = tournament.pairing_system == "keizer"

    # Bounded by the publish gate, same as the OpenResults snapshot. Without
    # it this page showed results for a round the public PAIRINGS page one
    # link away deliberately hides - so an arbiter withholding a round
    # withheld who played whom and published the results anyway.
    #
    # `published_through_round/1` is the contiguous prefix, not the highest
    # published round: see its own doc for why the difference matters.
    through = Tournaments.published_through_round(tournament)

    entries =
      if keizer? do
        Keizer.standings(tournament, through_round: through)
      else
        tournament
        |> Standings.standings(through_round: through)
        |> Standings.apply_manual_ranking(tournament)
      end

    assign(socket,
      keizer?: keizer?,
      entries: entries,
      rounds_paired: Standings.rounds_paired(tournament.id),
      manual_stale?:
        !keizer? and tournament.manual_ranking and Standings.manual_ranking_stale?(tournament),
      manual_incomplete?:
        !keizer? and tournament.manual_ranking and Standings.manual_ranking_incomplete?(entries)
    )
  end

  defp format_tb(value) when is_float(value) do
    if value == Float.round(value, 0), do: trunc(value), else: value
  end

  defp format_tb(value), do: value

  # Same "-" convention PrintController's/StandingsLive's standings
  # tables already use for a player with no category assigned.
  defp category_or_dash(nil), do: "-"
  defp category_or_dash(""), do: "-"
  defp category_or_dash(category), do: category

  defp tb_name(code), do: (Tiebreaks.get(code) || %{name: code}).name

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.public flash={@flash} current_path={assigns[:current_path]}>
      <div :if={@gone} class="card empty">
        <p><strong>This tournament is no longer available.</strong></p>
      </div>

      <div :if={!@gone}>
        <div class="page-header">
          <div>
            <h1>{@tournament.name}</h1>

            <p class="subtitle" style="margin: 0">
              Standings{if @rounds_paired > 0, do: " after round #{@rounds_paired}"}
            </p>

            <.public_tournament_meta tournament={@tournament} />
          </div>

          <div class="actions" style="margin: 0">
            <.link navigate={~p"/p/#{@slug}/pairings"} class="pe-btn">
              Pairings &amp; round history
            </.link>
          </div>
        </div>

        <div
          :if={@tournament.manual_ranking and !@keizer?}
          class="manual-ranking-banner"
          style="margin-bottom: 8px; padding: 8px 12px; border: 2px solid var(--color-warning, #b45309); border-radius: 6px;"
        >
          <strong>Manual ranking is ON.</strong>
          The rank column below reflects the arbiter's
          hand-set order, not the computed tiebreak order.
          <span :if={@manual_incomplete?}>
            A player was added after this was turned on and hasn't been placed yet.
          </span>

          <span :if={@manual_stale?}>
            <strong>A result changed since this order was last set - it may no longer match the
            real standings.</strong>
          </span>
        </div>

        <div :if={@entries == []} class="card empty">
          <p><strong>No players registered yet.</strong></p>
        </div>

        <div :if={@entries != [] and !@keizer?} class="card table-card">
          <table class="pe-table">
            <thead>
              <tr>
                <th class="num">Rank</th>

                <th>Name</th>

                <th class="num">Elo</th>

                <th class="num">Pts</th>

                <th :for={code <- @tournament.tiebreaks} class="num" title={tb_name(code)}>
                  {code}
                </th>

                <th :if={@tournament.categories != []}>Category</th>
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
                  {if Player.rating(entry.player) > 0, do: Player.rating(entry.player), else: "-"}
                </td>

                <td class="num"><strong>{entry.points}</strong></td>

                <td :for={code <- @tournament.tiebreaks} class="num">
                  {format_tb(Map.get(entry.tiebreaks, code, 0.0))}
                </td>

                <td :if={@tournament.categories != []}>{category_or_dash(entry.player.category)}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <div :if={@entries != [] and @keizer?} class="card table-card">
          <table class="pe-table">
            <thead>
              <tr>
                <th class="num">Rank</th>

                <th>Name</th>

                <th class="num">Elo</th>

                <th class="num">Value</th>

                <th class="num">Keizer pts</th>

                <th class="num">Score</th>

                <th :if={@tournament.categories != []}>Category</th>
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
                  {if Player.rating(entry.player) > 0, do: Player.rating(entry.player), else: "-"}
                </td>

                <td class="num">{entry.value}</td>

                <td class="num"><strong>{entry.points}</strong></td>

                <td class="num">{entry.raw_points}</td>

                <td :if={@tournament.categories != []}>{category_or_dash(entry.player.category)}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <p :if={@keizer?} class="hint">
          Keizer points, not FIDE tiebreaks - the whole ladder is recalculated from
          results, byes and absences every time.
        </p>
      </div>
    </Layouts.public>
    """
  end
end
