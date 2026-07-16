defmodule PairingsEngineWeb.PairingExplainLive do
  @moduledoc """
  "Why were these players paired this way?" — a live, visual explanation of a
  single round's pairings, computed fresh from current data by
  `PairingsEngine.PairingRationale` (the same analysis behind the audit
  trail's `"pairing.round_paired"` entry).

  For each board it shows both players' pre-round score, starting rank and
  colour (with FIDE due-colour agreement), flags floaters (a pairing that
  crosses score brackets — someone "paired up" or "paired down"), confirms no
  rematch, and names the pairing-allocated bye recipient. Round-robin shows
  the deterministic Berger-schedule slot; Keizer shows ladder values.

  Access control matches every other tournament page
  (`Tournaments.get_authorized_tournament!/2`).
  """
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.{PairingRationale, Tournaments}
  alias PairingsEngine.Tournaments.Player

  @impl true
  def mount(%{"id" => id, "round" => round}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)
    round_number = String.to_integer(round)
    rationale = PairingRationale.for_round(tournament, round_number)

    {:ok,
     assign(socket,
       tournament: tournament,
       round_number: round_number,
       rationale: rationale,
       page_title: "#{tournament.name} · Round #{round_number} explained"
     )}
  end

  ## ---------- display helpers ----------

  defp player_label(nil), do: "—"

  defp player_label(%Player{} = p) do
    rating = Player.rating(p)
    "#{if p.title not in [nil, ""], do: "#{p.title} "}#{p.name}#{if rating > 0, do: " (#{rating})", else: ""}"
  end

  defp score_str(nil), do: "0"
  defp score_str(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 1)
  defp score_str(n), do: to_string(n)

  defp colour_word(:w), do: "White"
  defp colour_word(:b), do: "Black"
  defp colour_word(_), do: "—"

  # A short human note about a side's colour vs. its FIDE due colour.
  defp colour_note(%{colour_due: nil}), do: "no colour history yet"
  defp colour_note(%{colour_ok: true, colour_due: due}), do: "matches due colour (#{colour_word(due)})"

  defp colour_note(%{colour_ok: false, colour_due: due}),
    do: "against due colour (#{colour_word(due)})"

  defp colour_note(_), do: ""

  defp float_note(%{floater: false}), do: nil

  defp float_note(%{white: w, black: b}) when not is_nil(b) do
    {high, low} = if w.score >= b.score, do: {w, b}, else: {b, w}

    "Floater — #{high.player.name} (#{score_str(high.score)}) paired down against " <>
      "#{low.player.name} (#{score_str(low.score)}), who paired up."
  end

  defp float_note(_), do: nil

  defp system_label("round_robin"), do: "Round robin (Berger schedule)"
  defp system_label("keizer"), do: "Keizer ladder"
  defp system_label(_), do: "Swiss (FIDE Dutch / JaVaFo)"

  @impl true
  def render(%{rationale: nil} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} tournament={@tournament} active="pairings">
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">Round {@round_number} — explanation</p>
        </div>
      </div>

      <div class="card error-note" style="display: block; margin: 12px 0">
        Round {@round_number} has not been paired yet, so there is nothing to explain.
        <.link navigate={~p"/t/#{@tournament.id}/pairings"}>Back to pairings</.link>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} tournament={@tournament} active="pairings">
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">
            Why round {@round_number} was paired this way — {system_label(@rationale.pairing_system)}
          </p>
        </div>
        <div class="actions" style="margin: 0">
          <.link class="pe-btn" navigate={~p"/t/#{@tournament.id}/pairings"}>Back to pairings</.link>
        </div>
      </div>

      <p class="hint" style="margin: 4px 0 12px">
        This is a live analysis of the current data (pre-round standings, colour history and
        pairing output), not a stored replay. JaVaFo's internal tie-break reasoning can't be
        extracted, so for Swiss this shows the input state that constrained the decision and the
        observable shape of its output (brackets, floaters, byes).
      </p>

      <div class="card" style="margin: 8px 0">
        <strong>Round {@round_number}:</strong>
        {@rationale.summary.boards} board(s), {@rationale.summary.byes} bye(s),
        {@rationale.summary.floaters} floater(s),
        {@rationale.summary.rematches} rematch(es).
      </div>

      <div :if={@rationale.berger} class="card" style="margin: 8px 0">
        <h3 style="margin-top: 0">Berger schedule</h3>
        <p :if={@rationale.berger.match_format} style="margin: 0">
          This is match {@rationale.berger.match_number}, leg {@rationale.berger.leg}. The whole
          schedule is fully determined by the number of players — there is no choice to explain.
        </p>
        <p :if={!@rationale.berger.match_format} style="margin: 0">
          Cycle {@rationale.berger.cycle} of {@rationale.berger.total_cycles}, schedule round
          {@rationale.berger.cycle_round}. The Berger table fixes every pairing in advance — this
          round's boards are the deterministic slot, not a computed choice.
        </p>
      </div>

      <div :if={@rationale.score_groups != []} class="card" style="margin: 8px 0">
        <h3 style="margin-top: 0">Pre-round score brackets</h3>
        <p class="hint" style="margin-top: 0">
          Players grouped by their standing going into this round. An odd bracket can't pair
          entirely within itself, so it floats a player to the neighbouring bracket.
        </p>
        <ul style="margin: 0">
          <li :for={g <- @rationale.score_groups}>
            <strong>{score_str(g.score)}</strong>
            — {g.count} player(s)
            <span :if={g.odd} class="badge">odd → floats one</span>
          </li>
        </ul>
      </div>

      <div class="card table-card">
        <table class="pe-table">
          <thead>
            <tr>
              <th class="num">Board</th>
              <th :if={@rationale.pair_by_category}>Category</th>
              <th>White</th>
              <th>Black</th>
              <th>Why</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={b <- @rationale.boards}>
              <td class="num">{b.board}</td>
              <td :if={@rationale.pair_by_category}>{b.category}</td>

              <td>
                <strong>{player_label(b.white.player)}</strong>
                <div class="hint">
                  score {score_str(b.white.score)} · start #{b.white.pairing_number}
                  <span :if={b.white.ladder_value}>· ladder {b.white.ladder_value}</span>
                  <br />White — {colour_note(b.white)}
                </div>
              </td>

              <td>
                <%= if b.is_bye do %>
                  <span class="badge">bye</span>
                <% else %>
                  <strong>{player_label(b.black.player)}</strong>
                  <div class="hint">
                    score {score_str(b.black.score)} · start #{b.black.pairing_number}
                    <span :if={b.black.ladder_value}>· ladder {b.black.ladder_value}</span>
                    <br />Black — {colour_note(b.black)}
                  </div>
                <% end %>
              </td>

              <td>
                <div :if={b.is_bye}>
                  <span class="badge">pairing-allocated bye</span>
                  <p :if={b[:bye_detail]} class="hint" style="margin: 4px 0 0">
                    {b.bye_detail.convention}
                    <span :if={b.bye_detail.had_prior_bye}>
                      <br /><strong>Note:</strong> this player already had a bye earlier.
                    </span>
                  </p>
                </div>

                <div :if={!b.is_bye}>
                  <span :if={b.floater} class="badge">floater</span>
                  <span :if={!b.floater} class="badge muted">same bracket</span>
                  <span :if={b.rematch} class="badge" style="background:#c0392b;color:#fff">
                    REMATCH
                  </span>
                  <span :if={!b.rematch} class="hint">no prior meeting ✓</span>
                  <p :if={float_note(b)} class="hint" style="margin: 4px 0 0">{float_note(b)}</p>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@rationale.byes.requested != []} class="card table-card" style="margin-top: 16px">
        <h3 style="margin: 0 0 8px">Requested / absence byes this round</h3>
        <table class="pe-table">
          <thead>
            <tr><th>Player</th><th>Type</th></tr>
          </thead>
          <tbody>
            <tr :for={rb <- @rationale.byes.requested}>
              <td>{player_label(rb.player)}</td>
              <td>{rb.type}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end
end
