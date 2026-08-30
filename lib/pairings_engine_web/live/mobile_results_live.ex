defmodule PairingsEngineWeb.MobileResultsLive do
  @moduledoc """
  The no-account mobile result-entry screen. Reached only via an active
  enrollment (see `PairingsEngineWeb.MobileAuth`), scoped to that one
  tournament. A helper taps a board and picks the result - nothing else is
  reachable from here.
  """
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.{Audit, Mobile, Standings, Tournaments}
  alias PairingsEngine.Tournaments.{Pairing, Player}

  @results [{"1-0", "1-0"}, {"1/2-1/2", "½-½"}, {"0-1", "0-1"}]

  # The rest of PairingsLive's own `@results` (forfeits and the asymmetric
  # disciplinary codes) - real results a helper at the board genuinely needs
  # to record, just rare enough that showing all 9 buttons on every board by
  # default would crowd the three that matter 95% of the time on a small
  # screen. Tucked behind "More…" (`toggle_extra/2`) instead of a long-press:
  # a long-press has no visible affordance at all (nothing on screen hints
  # it exists), fires inconsistently across mobile browsers, and collides
  # with the OS's own text-selection/context-menu gesture on many devices -
  # a plain, visible, always-there button is more reliable AND more
  # discoverable for exactly the audience (arbiters/helpers, not the
  # tournament owner) most likely to be seeing this screen for the first
  # time mid-round.
  @extra_results [
    {"1/2-0", "½-0 (asymmetric)"},
    {"0-1/2", "0-½ (asymmetric)"},
    {"1-0FF", "1-0 FF"},
    {"0-1FF", "0-1 FF"},
    {"0-0FF", "0-0 FF (double forfeit)"},
    {"0-0", "0-0 (both lose, played)"},
    {"1-0U", "1-0 (played, not rated)"},
    {"0-1U", "0-1 (played, not rated)"},
    {"1/2-1/2U", "½-½ (played, not rated)"}
  ]

  # Every code an arbiter may write, from the one table
  # (`PairingsEngine.Results`) rather than typed out again here. This screen
  # used to carry a hand-copied ten-item list under a comment claiming it
  # mirrored the Pairings page; it had been missing the three unrated codes
  # since the day they shipped, so a helper's phone could not record a
  # played-but-unrated game that the same round could record by click.
  @entry_codes PairingsEngine.Results.entry_codes()

  # The buttons must offer everything the guard accepts, minus the blank
  # (cleared by tapping the chosen result again, not by its own button).
  # A build that drifts from that fails here rather than shipping a button
  # that writes nothing, or a code with no way to enter it.
  @offered Enum.map(@results ++ @extra_results, &elem(&1, 0))
  @expected @entry_codes -- [""]
  if Enum.sort(@offered) != Enum.sort(@expected) do
    raise "mobile result buttons have drifted from PairingsEngine.Results.entry_codes/0: " <>
            "#{inspect(@offered -- @expected)} offered here only, " <>
            "#{inspect(@expected -- @offered)} missing here"
  end

  @impl true
  def mount(_params, _session, socket) do
    tournament = socket.assigns.tournament

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    paired = Engine.paired_rounds_count(tournament.id)

    {:ok,
     socket
     |> assign(
       page_title: "Enter results",
       results: @results,
       extra_results: @extra_results,
       paired: paired,
       archived?: not is_nil(tournament.archived_at),
       locked: false,
       # Which board's "More…" panel is open, if any - one at a time, so
       # the page doesn't grow tall with several boards expanded at once.
       # Cleared on round switch (below) since the boards it referred to no
       # longer apply.
       expanded_id: nil
     )
     |> load_round(max(paired, 1))}
  end

  @impl true
  def handle_info({:tournament_changed, _id, _hint}, socket) do
    # `on_mount(:require_enrollment, ...)` only loads `tournament` once, at
    # connect - reload it here too, or an archive/unarchive elsewhere would
    # never reach this page and the result buttons would stay stuck in
    # whichever `disabled?` state was true at the moment this phone opened
    # the page.
    tournament = Tournaments.get_tournament(socket.assigns.tournament.id)

    socket =
      if tournament,
        do: assign(socket, tournament: tournament, archived?: not is_nil(tournament.archived_at)),
        else: socket

    {:noreply, load_round(socket, socket.assigns.round_number)}
  end

  @impl true
  def handle_event("select_round", %{"number" => number}, socket) do
    {:noreply, socket |> assign(expanded_id: nil) |> load_round(String.to_integer(number))}
  end

  # A "hand the phone to someone else / put it down for a second" guard, not
  # a security boundary - off by default (per-session, resets on reload), and
  # purely to stop an accidental tap from overwriting a result. The buttons
  # are also `disabled` client-side, but this is the actual enforcement.
  def handle_event("toggle_lock", _params, socket) do
    {:noreply, assign(socket, locked: !socket.assigns.locked)}
  end

  # Opens/closes one board's "More…" panel (the forfeit/asymmetric codes -
  # see `@extra_results`). Only one open at a time: opening a different
  # board's panel closes whichever was already open, same as an accordion.
  def handle_event("toggle_extra", %{"id" => id}, socket) do
    id = String.to_integer(id)
    current = socket.assigns.expanded_id
    {:noreply, assign(socket, expanded_id: if(current == id, do: nil, else: id))}
  end

  def handle_event("set_result", _params, socket)
      when socket.assigns.locked or socket.assigns.archived?,
      do: {:noreply, socket}

  # Only pairings belonging to the loaded round (which is loaded from the
  # enrollment's own tournament) can be set - a crafted pairing id from
  # another tournament simply isn't in the set and is ignored. The codes
  # accepted are every code an arbiter may write, from `@entry_codes` above:
  # mobile shows three by default, but anything reachable through "More…"
  # has to actually be writable too.
  def handle_event("set_result", %{"id" => id, "result" => result}, socket)
      when result in @entry_codes do
    # Re-validate the enrollment on every write so a revoked or expired phone
    # is kicked out immediately, not only on its next page load.
    if Mobile.get_active(socket.assigns.mobile_enrollment.id) do
      round = socket.assigns.round

      case round && Enum.find(round.pairings, &(to_string(&1.id) == id)) do
        %Pairing{} = pairing ->
          previous = pairing.result

          socket =
            case Tournaments.update_pairing_result(pairing, result) do
              {:ok, _} ->
                log_mobile_result(socket, pairing, previous, result)
                socket

              {:error, :archived} ->
                put_flash(
                  socket,
                  :error,
                  "This tournament is archived - the arbiter needs to unarchive it before results can be entered."
                )

              {:error, _reason} ->
                put_flash(socket, :error, "Could not save that result.")
            end

          {:noreply, load_round(socket, socket.assigns.round_number)}

        _ ->
          {:noreply, socket}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "This phone's access was ended by the arbiter.")
       |> redirect(to: ~p"/m")}
    end
  end

  def handle_event("set_result", _params, socket), do: {:noreply, socket}

  # No-account phones weren't writing to the audit trail at all before this -
  # a real gap, since a mobile-entered result is exactly as write-worthy as
  # one entered from PairingsLive (same `Audit.log/4` action names, so the
  # audit page's existing "pairings" filter and describe/2 clauses pick
  # these up automatically), just with no `Scope`/user to attribute it to.
  # `Audit.log/4`'s `nil` case handles that ("System" in the audit UI) - the
  # enrollment's own id/code/label are threaded into `details` instead, so
  # an arbiter can still tell which phone made the change even without a
  # user account attached to it.
  defp log_mobile_result(socket, pairing, previous, result) do
    tournament = socket.assigns.tournament
    enrollment = socket.assigns.mobile_enrollment

    action =
      cond do
        result == "" -> "pairing.result_cleared"
        previous in [nil, ""] -> "pairing.result_entered"
        true -> "pairing.result_changed"
      end

    Audit.log(tournament.id, nil, action, %{
      pairing_id: pairing.id,
      round: socket.assigns.round_number,
      board: pairing.board,
      white: player_name(pairing.white_player),
      black: player_name(pairing.black_player),
      from: previous,
      to: result,
      via: "mobile",
      enrollment_id: enrollment.id,
      enrollment_code: enrollment.code,
      enrollment_label: enrollment.label
    })
  end

  defp player_name(nil), do: nil
  defp player_name(%Player{name: name}), do: name

  defp load_round(socket, number) do
    tournament = socket.assigns.tournament
    round = Tournaments.get_round(tournament.id, number)

    boards =
      case round do
        nil -> []
        r -> r.pairings |> Enum.reject(&(&1.black_player_id == nil)) |> Enum.sort_by(& &1.board)
      end

    # Score shown alongside each name is the player's total entering this
    # round (same convention as a printed pairing sheet) - not their live
    # score once this round's own results start coming in.
    scores =
      tournament
      |> Standings.standings(through_round: number - 1)
      |> Map.new(&{&1.player.id, &1.points})

    assign(socket, round_number: number, round: round, boards: boards, scores: scores)
  end

  defp player_meta(nil, _scores), do: ""

  defp player_meta(player, scores) do
    rating = Player.rating(player)
    points = format_score(Map.get(scores, player.id, 0.0))

    [if(rating > 0, do: "#{rating}"), "#{points} pts"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp format_score(v) when is_float(v) do
    if v == Float.round(v, 0), do: trunc(v), else: v
  end

  defp format_score(v), do: v

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mobile-shell">
      <header class="mobile-header">
        <div>
          <div class="mobile-brand">Open<strong>Pairings</strong></div>
          <div class="mobile-tname">{@tournament.name}</div>
        </div>
        <div class="mobile-header-actions">
          <button
            type="button"
            class={["mobile-lock-btn", @locked && "active"]}
            phx-click="toggle_lock"
            title={if @locked, do: "Unlock result entry", else: "Lock result entry"}
            aria-label={if @locked, do: "Unlock result entry", else: "Lock result entry"}
          >
            {if @locked, do: "🔒", else: "🔓"}
          </button>
          <Layouts.theme_switch />
          <.link href={~p"/m/leave"} class="mobile-leave">Leave</.link>
        </div>
      </header>

      <div :if={@paired > 1} class="mobile-rounds">
        <button
          :for={n <- 1..@paired}
          type="button"
          class={["mobile-round-btn", n == @round_number && "active"]}
          phx-click="select_round"
          phx-value-number={n}
        >
          R{n}
        </button>
      </div>

      <p class="mobile-hint">
        Round {@round_number} ·
        <%= if @locked do %>
          🔒 locked - tap the lock to enter results
        <% else %>
          tap a result for each board
        <% end %>
      </p>

      <div :if={@boards == []} class="mobile-empty">No boards paired for this round yet.</div>

      <div :for={p <- @boards} class="mobile-board">
        <div class="mobile-board-head">
          <span class="mobile-board-no">Board {p.board}</span>
        </div>
        <div class="mobile-players">
          <div class="mobile-side">
            <span class="mobile-white">{p.white_player && p.white_player.name}</span>
            <span class="mobile-meta">{player_meta(p.white_player, @scores)}</span>
          </div>
          <span class="mobile-vs">vs</span>
          <div class="mobile-side mobile-side--black">
            <span class="mobile-black">{p.black_player && p.black_player.name}</span>
            <span class="mobile-meta">{player_meta(p.black_player, @scores)}</span>
          </div>
        </div>
        <div class="mobile-results">
          <button
            :for={{value, label} <- @results}
            type="button"
            disabled={@locked || @archived?}
            class={["mobile-result-btn", p.result == value && "chosen"]}
            phx-click="set_result"
            phx-value-id={p.id}
            phx-value-result={value}
          >
            {label}
          </button>
          <button
            :if={p.result != ""}
            type="button"
            disabled={@locked || @archived?}
            class="mobile-result-btn mobile-clear"
            phx-click="set_result"
            phx-value-id={p.id}
            phx-value-result=""
            title="Clear the result"
          >
            ⟲
          </button>
          <button
            type="button"
            disabled={@locked || @archived?}
            class={["mobile-result-btn", "mobile-more", @expanded_id == p.id && "chosen"]}
            phx-click="toggle_extra"
            phx-value-id={p.id}
          >
            {if @expanded_id == p.id, do: "▲ Less", else: "▼ More"}
          </button>
        </div>

        <%!-- Forfeits and the asymmetric disciplinary codes - rare, so
              tucked here instead of cluttering every board's default three
              buttons. Stays open if that's already this board's own
              recorded result, so "what's currently set" is never hidden
              behind a tap the arbiter has no reason to make. --%>
        <div
          :if={@expanded_id == p.id or (p.result != "" and p.result not in ~w(1-0 1/2-1/2 0-1))}
          class="mobile-results mobile-results--extra"
        >
          <button
            :for={{value, label} <- @extra_results}
            type="button"
            disabled={@locked || @archived?}
            class={["mobile-result-btn", p.result == value && "chosen"]}
            phx-click="set_result"
            phx-value-id={p.id}
            phx-value-result={value}
          >
            {label}
          </button>
        </div>
      </div>
    </div>
    """
  end
end
