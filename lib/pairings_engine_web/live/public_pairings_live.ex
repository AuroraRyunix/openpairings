defmodule PairingsEngineWeb.PublicPairingsLive do
  @moduledoc """
  Public (no login required) read-only view of a tournament's paired
  rounds - reachable at `/p/:slug/pairings` where `:slug` is the
  tournament's unguessable `public_slug` (see docs/public-pages.md), not
  its numeric id. Anyone holding the link can view it; nothing here is
  editable. Subscribes to the tournament's PubSub topic and reloads live
  when results are entered elsewhere, same as the authenticated pages.

  Defaults to the latest paired round, but carries a `?round=N` query param
  (via `<.link patch=...>`, same pattern PrintController's round links
  use) so any past round's history is reachable and bookmarkable/shareable
  - not just whatever is currently being paired. Mirrors the authenticated
  Pairings page's round-picker (`PairingsLive`'s `round-picker` div), minus
  the editing controls.
  """

  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.Components.PublicTournamentMeta

  alias PairingsEngine.{Tournaments, Standings, PairingDisplay}

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
  def mount(%{"slug" => slug}, _session, socket) do
    tournament =
      Tournaments.get_tournament_by_public_slug(slug) ||
        raise Ecto.NoResultsError, queryable: Tournaments.Tournament

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    {:ok,
     assign(socket,
       tournament: tournament,
       slug: slug,
       page_title: "#{tournament.name} · Pairings",
       gone: false
     )}
  end

  # `?round=N` drives which round is shown - handled here (not in mount/3)
  # so clicking a round-picker button patches the URL without a full
  # remount/re-subscribe. Missing/invalid/out-of-range values fall back to
  # the latest paired round, same as before this param existed.
  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, reload(socket, params["round"])}
  end

  @impl true
  def handle_info({:tournament_changed, _tournament_id, _hint}, socket) do
    case Tournaments.get_tournament_by_public_slug(socket.assigns.slug) do
      nil ->
        {:noreply, assign(socket, gone: true)}

      tournament ->
        # Preserve whichever round the visitor is currently looking at -
        # an unrelated broadcast (someone else's result elsewhere) must not
        # yank them back to the latest round mid-read.
        {:noreply,
         socket
         |> assign(tournament: tournament)
         |> reload(socket.assigns[:round_number])}
    end
  end

  defp reload(socket, requested) do
    tournament = socket.assigns.tournament
    # The bound for both the default round and the "how far can `?round=N`
    # reach" check is the latest *published* round, not the latest paired
    # one - `Pairing.paired_rounds_count/1` would leak that a round exists
    # (and default visitors to it) before the arbiter meant it to be seen.
    # For "immediate" mode (the common case) these two counts are always
    # equal, since every paired round is published the instant it's made.
    published = Tournaments.latest_published_round_number(tournament)

    round_number =
      with val when val != nil <- requested,
           {n, ""} <- Integer.parse(to_string(val)),
           true <- n >= 1 and n <= tournament.rounds_count do
        n
      else
        _ -> max(published, 1)
      end

    # Fetch first, then gate on `round_published?/2` - NOT `round_number <=
    # published`, because `latest_published_round_number/1` only tracks the
    # *highest* published round number. In "manual" mode an arbiter can
    # publish round 3 while leaving round 2 hidden (published out of
    # order), so a plain `<=` check would wrongly show round 2 just
    # because round 3 happens to be public. A round that isn't paired at
    # all comes back `nil` from `get_round/2` and reads the same as one
    # that's paired-but-unpublished - the public side has no way (and no
    # need) to tell those two apart.
    round =
      case Tournaments.get_round(tournament.id, round_number) do
        nil -> nil
        candidate -> if Tournaments.round_published?(tournament, candidate), do: candidate
      end

    assign(socket,
      round_number: round_number,
      paired_rounds: published,
      round: round,
      scores:
        if(round, do: Standings.player_scores_before_round(tournament, round_number), else: %{}),
      round_byes:
        if(round, do: Tournaments.list_byes_for_round(tournament.id, round_number), else: [])
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

  # Same match/leg round-label scheme as the authenticated Pairings page's
  # round-picker (`PairingsLive.round_label/2`/`match_format?/1`), so a
  # match-format tournament's public link reads "M1·1" here too instead of
  # a bare round number.
  defp match_format?(%Tournaments.Tournament{rr_match_format: true}), do: true
  defp match_format?(%Tournaments.Tournament{swiss_match_format: true}), do: true
  defp match_format?(_), do: false

  defp round_label(n, tournament) do
    if match_format?(tournament) do
      "M#{match_number(n)}·#{leg_number(n)}"
    else
      to_string(n)
    end
  end

  defp round_heading(n, tournament) do
    if match_format?(tournament) do
      "Match #{match_number(n)}, game #{leg_number(n)}"
    else
      "Round #{n}"
    end
  end

  defp match_number(n), do: div(n - 1, 2) + 1
  defp leg_number(n), do: if(rem(n, 2) == 1, do: 1, else: 2)

  # Same display logic the authenticated Pairings page uses
  # (`PairingsEngineWeb.PairingsLive.display_rows/1`) - fixed-table
  # ("special") boards renumbered/relabeled and moved to the end, byes and
  # vacant seats sorted below those, real boards renumbered to close the
  # gap. Before this, the public page just sorted by raw `pairing.board`,
  # so it silently disagreed with the private page (and print) on both
  # the board LABEL and the row ORDER the moment a tournament had a
  # fixed-table player, a bye, or an absence - real board 10 showed "10"
  # here and "1001" there, for the exact same game.
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.public flash={@flash}>
      <div :if={@gone} class="card empty">
        <p><strong>This tournament is no longer available.</strong></p>
      </div>

      <div :if={!@gone}>
        <div class="page-header">
          <div>
            <h1>{@tournament.name}</h1>
            <p class="subtitle" style="margin: 0">
              <%= if @paired_rounds > 0 do %>
                Pairings &middot; {round_heading(@round_number, @tournament)}
              <% else %>
                Pairings &middot; no rounds published yet
              <% end %>
            </p>

            <.public_tournament_meta tournament={@tournament} />
          </div>

          <div class="actions" style="margin: 0">
            <.link navigate={~p"/p/#{@slug}/standings"} class="pe-btn">Standings</.link>
          </div>
        </div>

        <div :if={@tournament.rounds_count > 1} class="round-picker">
          <.link
            :for={n <- 1..@tournament.rounds_count}
            patch={~p"/p/#{@slug}/pairings?round=#{n}"}
            class={[
              "pe-btn",
              match_format?(@tournament) && "filter-picker",
              n == @round_number && "active"
            ]}
          >
            {round_label(n, @tournament)}
          </.link>
        </div>

        <div :if={@round == nil} class="card empty" style="margin-top: 16px">
          <p>
            <strong>
              <%= if @paired_rounds > 0 do %>
                Round {@round_number} hasn't been published yet.
              <% else %>
                No round has been published yet.
              <% end %>
            </strong>
          </p>
        </div>

        <div :if={@round} class="card table-card" style="margin-top: 16px">
          <table class="pe-table">
            <thead>
              <tr>
                <th class="num">Board</th>
                <th>White</th>
                <th style="text-align: center; width: 160px">Result</th>
                <th>Black</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={%{pairing: pairing, board: display_board} <- display_rows(@round.pairings)}>
                <td class="num">{display_board}</td>
                <td><strong>{seat_label(pairing.white_player, @scores)}</strong></td>
                <td style="text-align: center">
                  <%= cond do %>
                    <% pairing.result == "bye" -> %>
                      <span class="badge">bye ({@tournament.bye_value} pt)</span>
                    <% pairing.result == "" -> %>
                      <span class="badge muted">in progress</span>
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
                <th>Player</th>
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
      </div>
    </Layouts.public>
    """
  end
end
