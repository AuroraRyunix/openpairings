defmodule PairingsEngineWeb.PairingsLive do
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport, only: [setup_field_path: 2]

  alias PairingsEngine.{Audit, PairingRationale, ResultsImport, Tournaments}
  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.Tournaments.Tournament

  @results [
    {"", "…"},
    {"1-0", "1-0"},
    {"1/2-1/2", "½-½"},
    {"0-1", "0-1"},
    {"1-0FF", "1-0 FF (White wins by forfeit)"},
    {"0-1FF", "0-1 FF (Black wins by forfeit)"},
    {"0-0FF", "0-0 FF (double forfeit)"},
    {"0-0", "0-0 (both lose, game played)"}
  ]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)
    paired = Engine.paired_rounds_count(tournament.id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    # Clears the "another arbiter" notice (see `handle_info` below) the
    # moment the user interacts with the page again — a self-clearing timer
    # alone would leave it sitting through an in-progress click, and there's
    # no harm clearing it eagerly since every mutating event already
    # refreshes the round data itself.
    socket =
      attach_hook(socket, :remote_notice_clear_on_click, :handle_event, fn _event,
                                                                           _params,
                                                                           socket ->
        {:cont, assign(socket, remote_notice: false)}
      end)

    {:ok,
     socket
     |> assign(
       tournament: tournament,
       page_title: "#{tournament.name} · Pairings",
       round_number: max(paired, 1),
       error: nil,
       importing_results: false,
       import_errors: nil,
       remote_notice: false
     )
     |> allow_upload(:results_csv, accept: :any, max_entries: 1, max_file_size: 2_000_000)
     |> refresh()}
  end

  # Results are entered inline (each select saves immediately on change, no
  # draft state to protect), so a broadcast can just reload everything —
  # including the tournament itself, since rounds_count/status can change
  # from the Settings page.
  #
  # This LiveView is subscribed to its own tournament's topic, so every
  # mutation it causes itself (pair/unpair/result/import) broadcasts right
  # back to this same process — but by the time that echo arrives, the
  # triggering `handle_event` has already called `refresh/1` synchronously,
  # so `@round` already reflects the new state. Comparing the *freshly
  # reloaded* round against what's already assigned tells the two cases
  # apart without any separate "was this my own action" bookkeeping: if
  # nothing changed, it was our own echo (or an unrelated broadcast, e.g. a
  # Settings-page edit that doesn't touch this round); if it differs, some
  # other process actually changed what's on screen, and only then is the
  # "updated by another arbiter" notice worth showing.
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
        old_round = socket.assigns.round
        socket = socket |> assign(tournament: tournament) |> refresh()

        socket =
          if socket.assigns.round != old_round do
            Process.send_after(self(), :clear_remote_notice, 4000)
            assign(socket, remote_notice: true)
          else
            socket
          end

        {:noreply, socket}
    end
  end

  def handle_info(:clear_remote_notice, socket) do
    {:noreply, assign(socket, remote_notice: false)}
  end

  defp refresh(socket) do
    %{tournament: t, round_number: n} = socket.assigns
    paired = Engine.paired_rounds_count(t.id)
    missing_setup = Tournament.missing_setup_fields(t)
    setup_complete = missing_setup == []

    assign(socket,
      round: Tournaments.get_round(t.id, n),
      round_byes: Tournaments.list_byes_for_round(t.id, n),
      paired_rounds: paired,
      next_pairable: paired + 1,
      setup_complete: setup_complete,
      missing_setup: missing_setup,
      recommended_missing: Tournament.missing_recommended_fields(t),
      can_pair:
        setup_complete and paired < t.rounds_count and Engine.round_complete?(t.id, paired)
    )
  end

  @impl true
  def handle_event("dismiss_remote_notice", _params, socket) do
    {:noreply, assign(socket, remote_notice: false)}
  end

  def handle_event("select_round", %{"number" => number}, socket) do
    {:noreply, socket |> assign(round_number: String.to_integer(number), error: nil) |> refresh()}
  end

  def handle_event("pair", _params, socket) do
    if not Tournament.setup_complete?(socket.assigns.tournament) do
      {:noreply,
       put_flash(
         socket,
         :error,
         "Finish the tournament setup before pairing — missing: " <>
           missing_setup_summary(socket.assigns.missing_setup)
       )}
    else
      do_pair(socket)
    end
  end

  def handle_event("unpair", _params, socket) do
    %{tournament: t, round_number: round_number} = socket.assigns

    case Engine.delete_round(t.id, round_number) do
      :ok ->
        Audit.log(t.id, socket.assigns.current_scope, "pairing.round_deleted", %{
          round: round_number
        })

        {:noreply, socket |> assign(error: nil) |> refresh()}

      {:error, reason} ->
        {:noreply, assign(socket, error: reason)}
    end
  end

  def handle_event("result", %{"pairing-id" => id, "result" => result}, socket) do
    %{tournament: t, round_number: round_number} = socket.assigns

    socket.assigns.round.pairings
    |> Enum.find(&(&1.id == String.to_integer(id)))
    |> case do
      nil ->
        :ok

      pairing ->
        previous = pairing.result

        case Tournaments.update_pairing_result(pairing, result) do
          {:ok, _} ->
            action =
              if previous in [nil, ""],
                do: "pairing.result_entered",
                else: "pairing.result_changed"

            Audit.log(t.id, socket.assigns.current_scope, action, %{
              pairing_id: pairing.id,
              round: round_number,
              board: pairing.board,
              white: player_name(pairing.white_player),
              black: player_name(pairing.black_player),
              from: previous,
              to: result
            })

          _ ->
            :ok
        end
    end

    {:noreply, refresh(socket)}
  end

  ## ---------- CSV results import ----------

  def handle_event("toggle_import_results", _params, socket) do
    {:noreply,
     assign(socket, importing_results: not socket.assigns.importing_results, import_errors: nil)}
  end

  # The file input's phx-change target; nothing to do until submit.
  def handle_event("validate_results_csv", _params, socket), do: {:noreply, socket}

  def handle_event("import_results_csv", _params, socket) do
    %{tournament: tournament, round_number: round_number} = socket.assigns

    uploaded =
      consume_uploaded_entries(socket, :results_csv, fn %{path: path}, _entry ->
        {:ok, File.read!(path)}
      end)

    case uploaded do
      [csv_text] ->
        with {:ok, rows} <- ResultsImport.parse_text(csv_text),
             {:ok, count} <- ResultsImport.apply_import(tournament, round_number, rows) do
          Audit.log(tournament.id, socket.assigns.current_scope, "pairing.results_imported", %{
            round: round_number,
            results_set: count
          })

          {:noreply,
           socket
           |> put_flash(:info, "Imported #{count} result#{if count != 1, do: "s"}.")
           |> assign(import_errors: nil, importing_results: false, error: nil)
           |> refresh()}
        else
          {:error, errors} -> {:noreply, assign(socket, import_errors: errors)}
        end

      [] ->
        {:noreply, assign(socket, import_errors: ["Choose a CSV file first"])}
    end
  end

  defp do_pair(socket) do
    case Engine.pair_next_round(socket.assigns.tournament) do
      {:ok, round} ->
        log_round_paired(socket, round.number)
        {:noreply, socket |> assign(round_number: round.number, error: nil) |> refresh()}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, assign(socket, error: "Could not save the round")}

      {:error, reason} ->
        {:noreply, assign(socket, error: to_string(reason))}
    end
  end

  # Logs the rich "pairing.round_paired" audit entry, reusing the exact same
  # PairingRationale analysis the "Explain this round" page renders live — so
  # the durable audit record and the visual page describe the same decision.
  # `swiss_match_format` pairs two rounds in one action; we log the primary
  # (leg-1) round number, whose rationale covers the decision that was made.
  defp log_round_paired(socket, round_number) do
    t = socket.assigns.tournament
    rationale = PairingRationale.for_round(t, round_number)

    Audit.log(
      t.id,
      socket.assigns.current_scope,
      "pairing.round_paired",
      PairingRationale.audit_payload(rationale)
    )
  end

  defp results, do: @results

  # Plain-text summary of `Tournament.missing_setup_fields/1`'s messages, for
  # the flash/tooltip shown when pairing is blocked — the on-page banner (see
  # render/1) additionally links each item to the Settings (sub-)page it
  # lives on.
  defp missing_setup_summary(missing) do
    Enum.map_join(missing, "; ", fn {_field, message} -> message end)
  end

  # Long JaVaFo failures come through as multi-line output — show a short
  # first-line preview as the collapsed summary, never a truncated message
  # (the full text is always available by expanding the block).
  defp error_summary(text) do
    text |> String.split("\n", parts: 2) |> hd()
  end

  # Display-only annotation for a board that involves a player with a
  # `fixed_board` override (SWAR "special table" — e.g. a wheelchair-access
  # table) — mirrors `PairingsEngineWeb.PrintController`'s "(table N)" note
  # on the printed pairing sheet (see docs/printing.md), so the same
  # information is visible on the Pairings page itself, not just on paper.
  # Real board renumbering happens nowhere; this purely flags it for the
  # arbiter.
  defp fixed_board_note(pairing) do
    boards =
      [pairing.white_player, pairing.black_player]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.fixed_board)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case boards do
      [] -> ""
      boards -> " (table #{Enum.join(boards, ", ")})"
    end
  end

  # Bare display name for an audit-log payload (nil = a bye's empty side).
  defp player_name(nil), do: nil
  defp player_name(player), do: player.name

  defp player_label(nil), do: ""

  defp player_label(player) do
    rating = PairingsEngine.Tournaments.Player.rating(player)

    "#{if player.title != "", do: "#{player.title} "}#{player.name}" <>
      if(rating > 0, do: " (#{rating})", else: "")
  end

  # A round's pairings preload in whatever order the DB/JaVaFo output them,
  # not board order — sort ascending by board so the table reads "Board 1,
  # Board 2, ..." top to bottom like a real pairing sheet.
  defp board_sorted(pairings), do: Enum.sort_by(pairings, & &1.board)

  # Label for a byes-table row's `type` — distinct from the "bye" badge
  # shown for a pairing-allocated bye (a real Pairing row), since these
  # never appear in round.pairings (see Tournaments.list_byes_for_round/2).
  defp bye_type_label("requested-half"), do: "requested half-point bye"
  defp bye_type_label("requested-zero"), do: "requested zero-point bye"
  defp bye_type_label("absent"), do: "absent"
  defp bye_type_label(other), do: other

  # Cosmetic-only: under `rr_match_format`/`swiss_match_format`, round
  # 2k-1/2k are legs 1/2 of the same "match" (Pairing.max_pairable_round/1,
  # RoundRobin.do_pair/3 — leg 2 is always a colour-reversed mirror of leg
  # 1, never a separate JaVaFo decision). `rounds_count` keeps meaning
  # "total physical rounds" everywhere else; this only changes what the
  # round-picker buttons and the "Round N" heading display.
  defp match_format?(%Tournament{rr_match_format: true}), do: true
  defp match_format?(%Tournament{swiss_match_format: true}), do: true
  defp match_format?(_), do: false

  defp round_label(n, tournament) do
    if match_format?(tournament) do
      "M#{match_number(n)}·#{leg_number(n)}"
    else
      to_string(n)
    end
  end

  # Same match/leg breakdown as `round_label/2`, but spelled out for the
  # "Round ..." heading below the picker, where the compact button label
  # would read ambiguously ("Round M1·1").
  defp round_heading(n, tournament) do
    if match_format?(tournament) do
      "Match #{match_number(n)}, game #{leg_number(n)}"
    else
      "Round #{n}"
    end
  end

  defp match_number(n), do: div(n - 1, 2) + 1
  defp leg_number(n), do: if(rem(n, 2) == 1, do: 1, else: 2)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      tournament={@tournament}
      active="pairings"
    >
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>

          <p class="subtitle" style="margin: 0">Pairings &amp; results</p>
        </div>

        <div class="actions" style="margin: 0">
          <a class="pe-btn" href={~p"/t/#{@tournament.id}/live"} target="_blank">
            Open live view
          </a>

          <a class="pe-btn" href={~p"/t/#{@tournament.id}/export/trf"} target="_blank">
            Export TRF (all rounds)
          </a>

          <form
            id="trf-rounds-export-form"
            method="get"
            action={~p"/t/#{@tournament.id}/export/trf"}
            target="_blank"
            style="display: flex; gap: 6px; align-items: center; margin: 0"
          >
            <input
              type="text"
              name="rounds"
              placeholder="e.g. 1-5 or 1,3,5"
              class="pe-select"
              style="width: 150px"
            />
            <button type="submit" class="pe-btn" title="Export only the rounds listed here">
              Export rounds…
            </button>
          </form>
        </div>
      </div>

      <p
        :if={@tournament.manual_ranking}
        class="hint"
        style="margin-top: -8px; margin-bottom: 12px"
      >
        Manual ranking is on for this tournament, but the TRF export's rank column reflects the
        computed/starting-rank order, not the arbiter's hand-set display order.
      </p>

      <div :if={!@setup_complete} class="card error-note" style="display: block; margin: 12px 0">
        Finish the tournament setup before pairing — still missing:
        <ul style="margin: 6px 0 0; padding-left: 20px">
          <li :for={{field, message} <- @missing_setup}>
            <.link navigate={setup_field_path(@tournament, field)}>{message}</.link>
          </li>
        </ul>
      </div>

      <div
        :if={@setup_complete and @recommended_missing != []}
        class="card"
        style="display: block; margin: 12px 0; border-left: 3px solid var(--accent)"
      >
        You're ready to pair. For a complete FIDE report, you may also want to fill in:
        <ul style="margin: 6px 0 0; padding-left: 20px">
          <li :for={{field, message} <- @recommended_missing}>
            <.link navigate={setup_field_path(@tournament, field)}>{message}</.link>
          </li>
        </ul>
      </div>

      <div class="round-picker">
        <button
          :for={n <- 1..@tournament.rounds_count}
          class={[
            "pe-btn",
            match_format?(@tournament) && "filter-picker",
            n == @round_number && "active"
          ]}
          phx-click="select_round"
          phx-value-number={n}
        >
          {round_label(n, @tournament)}
        </button>
      </div>

      <div
        :if={@remote_notice}
        class="card"
        style="display: flex; align-items: center; justify-content: space-between; gap: 8px; margin: 12px 0; padding: 8px 12px; border-left: 3px solid var(--accent)"
      >
        <span>Round {@round_number} was just updated by another arbiter — refreshed.</span>
        <button
          type="button"
          class="pe-btn"
          style="padding: 2px 8px"
          phx-click="dismiss_remote_notice"
        >
          Dismiss
        </button>
      </div>

      <div class="page-header" style="margin-top: 16px">
        <div>
          <h2 style="margin: 0">{round_heading(@round_number, @tournament)}</h2>

          <p class="subtitle" style="margin: 0">
            <span class={["badge", @round == nil && "muted"]}>
              {cond do
                @round == nil -> "not paired"
                Enum.any?(@round.pairings, &(&1.result == "")) -> "playing"
                true -> "finished"
              end}
            </span>
          </p>
        </div>

        <div class="actions" style="margin: 0">
          <button
            :if={@round == nil && @round_number == @next_pairable}
            class="pe-btn primary"
            phx-click="pair"
            disabled={!@can_pair}
            title={
              cond do
                !@setup_complete ->
                  "Finish the tournament setup first — missing: " <>
                    missing_setup_summary(@missing_setup)

                !@can_pair ->
                  "Previous round still has missing results"

                true ->
                  nil
              end
            }
          >
            Pair round {@round_number} (JaVaFo)
          </button>

          <div
            :if={@round != nil}
            class="print-menu-wrap"
            phx-hook=".PrintMenu"
            id={"print-pairings-menu-#{@round_number}"}
          >
            <a
              class="pe-btn"
              href={~p"/t/#{@tournament.id}/print/pairings?round=#{@round_number}"}
              target="_blank"
              title="Right-click for more print options"
            >
              Print pairings <span class="print-menu-affordance">⋯</span>
            </a>

            <div class="print-menu-items" hidden>
              <a
                href={~p"/t/#{@tournament.id}/print/pairings?round=#{@round_number}&absentees=1"}
                target="_blank"
                title="Same pairing sheet, with a below-the-table section listing requested byes and absences"
              >
                With absentees section
              </a>
            </div>
          </div>

          <a
            :if={@round != nil}
            class="pe-btn"
            href={~p"/t/#{@tournament.id}/print/standings?round=#{@round_number}"}
            target="_blank"
          >
            Print standings
          </a>

          <div
            :if={@round != nil}
            class="print-menu-wrap"
            phx-hook=".PrintMenu"
            id={"print-results-menu-#{@round_number}"}
          >
            <a
              class="pe-btn"
              href={~p"/t/#{@tournament.id}/print/results?round=#{@round_number}"}
              target="_blank"
              title="Right-click for more print options"
            >
              Print result cards <span class="print-menu-affordance">⋯</span>
            </a>

            <div class="print-menu-items" hidden>
              <a
                href={~p"/t/#{@tournament.id}/print/results?round=#{@round_number}&limit=3"}
                target="_blank"
                title="Print just the first 3 result cards, to check printer alignment before printing the full stack"
              >
                Test print (first 3 cards)
              </a>

              <a
                href={~p"/t/#{@tournament.id}/print/results?round=#{@round_number}&order=stack"}
                target="_blank"
                title="Reorders cards so guillotine-cutting the printed stack into 8 piles and collating them recovers board order"
              >
                Stack-cut order
              </a>
            </div>
          </div>

          <a
            :if={@round != nil}
            class="pe-btn"
            href={~p"/t/#{@tournament.id}/export/pgn?round=#{@round_number}"}
            target="_blank"
            title="Metadata-only PGN — no moves are recorded in OpenPairings"
          >
            Export PGN
          </a>

          <button
            :if={@round != nil}
            class="pe-btn"
            phx-click="toggle_import_results"
          >
            Import results (CSV)
          </button>

          <button
            :if={@round != nil && @round_number == @paired_rounds}
            class="pe-btn danger-link"
            phx-click="unpair"
            data-confirm={"Unpair round #{@round_number}? All its results will be deleted."}
          >
            Unpair round
          </button>
        </div>
      </div>

      <div :if={@error} class="error-note" style="display: block">
        <details open={String.length(@error) <= 160}>
          <summary style="cursor: pointer">{error_summary(@error)}</summary>
          <pre style="max-height: 320px; overflow: auto; white-space: pre-wrap; word-break: break-word; margin: 6px 0 0">{@error}</pre>
        </details>
      </div>

      <form
        :if={@importing_results}
        id="results-csv-import-form"
        class="card"
        phx-submit="import_results_csv"
        phx-change="validate_results_csv"
        style="margin: 8px 0"
      >
        <h3 style="margin-top: 0">Import results (CSV) — round {@round_number}</h3>

        <p class="hint" style="margin-top: 0">
          One line per board: <code>board,result</code>
          (or <code>;</code>-separated).
          Results: <code>1-0</code>, <code>0-1</code>, <code>1/2-1/2</code>
          (or <code>=</code>), <code>0-0</code>
          (both lose, played), <code>1-0FF</code>/<code>0-1FF</code>
          (forfeit win), <code>0-0FF</code>
          (double forfeit). Boards left out keep their current result.
        </p>

        <div
          class={["dropzone", @uploads.results_csv.entries != [] && "has-file"]}
          phx-drop-target={@uploads.results_csv.ref}
        >
          <.live_file_input upload={@uploads.results_csv} class="dropzone-input" />
          <div class="dropzone-label">
            <%= if @uploads.results_csv.entries == [] do %>
              <strong>Choose a .csv file</strong> <span class="hint">or drag and drop it here</span>
            <% else %>
              <span :for={entry <- @uploads.results_csv.entries} class="dropzone-file">
                {entry.client_name}
              </span>
            <% end %>
          </div>
        </div>

        <p :for={err <- upload_errors(@uploads.results_csv)} class="error-note">{inspect(err)}</p>

        <div :if={@import_errors} class="error-note" style="display: block">
          <strong>Nothing was saved — fix these and try again:</strong>
          <ul style="margin: 6px 0 0">
            <li :for={err <- @import_errors}>{err}</li>
          </ul>
        </div>

        <div class="actions">
          <button type="submit" class="pe-btn primary">Import</button>
          <button type="button" class="pe-btn" phx-click="toggle_import_results">Cancel</button>
        </div>
      </form>

      <p class="hint" style="margin: 8px 0">
        Tip: click a result box and press 1 / 2 / 3 (top row or numpad, any keyboard layout) to enter results rapidly (white win / draw / black win) — focus jumps to the next board automatically.
      </p>

      <div class="card table-card">
        <table class="pe-table">
          <thead>
            <tr>
              <th class="num">Board</th>

              <th>White</th>

              <th style="text-align: center; width: 220px">Result</th>

              <th>Black</th>
            </tr>
          </thead>

          <tbody>
            <tr :if={@round == nil}>
              <td colspan="4">
                <div class="empty">
                  <p><strong>This round has not been paired yet.</strong></p>

                  <p class="hint">
                    <%= if @round_number == @next_pairable do %>
                      Press "Pair round {@round_number}" to run the FIDE Dutch pairing (JaVaFo).
                    <% else %>
                      Rounds are paired in order — round {@next_pairable} is next.
                    <% end %>
                  </p>
                </div>
              </td>
            </tr>

            <tr :for={pairing <- board_sorted((@round && @round.pairings) || [])}>
              <td class="num">{pairing.board}{fixed_board_note(pairing)}</td>

              <td><strong>{player_label(pairing.white_player)}</strong></td>

              <td style="text-align: center">
                <%= if pairing.result == "bye" do %>
                  <span class="badge">bye ({@tournament.bye_value} pt)</span>
                <% else %>
                  <form phx-change="result" id={"result-form-#{pairing.id}"}>
                    <input type="hidden" name="pairing-id" value={pairing.id} />
                    <select
                      name="result"
                      class="pe-select"
                      id={"result-select-#{pairing.id}"}
                      phx-hook=".BlindResultEntry"
                      data-board-select
                    >
                      <option
                        :for={{value, label} <- results()}
                        value={value}
                        selected={pairing.result == value}
                      >
                        {label}
                      </option>
                    </select>
                  </form>
                <% end %>
              </td>

              <td>{player_label(pairing.black_player)}</td>
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
                  {bye_type_label(bye.type)} ({PairingsEngine.Standings.bye_points(
                    bye.type,
                    @tournament
                  )} pt)
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".BlindResultEntry">
        // SWAR-style "blind" result entry: with a board's result <select>
        // focused, typing 1 / 2 / 3 sets that board's result (white win /
        // draw / black win) and moves focus to the next board's result
        // select, so a sequence like "131312" fills in six boards in a row
        // without touching the mouse.
        // Mapped by PHYSICAL key (e.code) so the top-row/numpad 1/2/3 keys
        // work on any keyboard layout (e.g. AZERTY, where the top row
        // produces & é " without Shift). e.key is kept as a fallback.
        const CODE_TO_VALUE = {
          "Digit1": "1-0", "Numpad1": "1-0",
          "Digit2": "1/2-1/2", "Numpad2": "1/2-1/2",
          "Digit3": "0-1", "Numpad3": "0-1"
        };
        const KEY_TO_VALUE = {"1": "1-0", "2": "1/2-1/2", "3": "0-1"};

        export default {
          mounted() {
            // A native <select> opens its dropdown on the same click that
            // focuses it — and while that native popup is open, the browser
            // intercepts number keys for its own "jump to option" behavior
            // before our keydown listener below ever sees them (confirmed:
            // typing did nothing until a second click closed the popup,
            // leaving the element focused-but-closed). Clicking to open a
            // fresh select is the arbiter's actual entry point for the "1/2/3"
            // workflow, so it must land focused-and-CLOSED in one click.
            // Only intercept the click that's ABOUT to focus this element —
            // if it's already focused, let a second click open the dropdown
            // normally (still needed to pick a code with no 1/2/3 shortcut,
            // e.g. a forfeit result).
            this.onMousedown = (e) => {
              if (document.activeElement !== this.el) {
                e.preventDefault();
                this.el.focus();
              }
            };
            this.el.addEventListener("mousedown", this.onMousedown);

            this.onKeydown = (e) => {
              const value = CODE_TO_VALUE[e.code] || KEY_TO_VALUE[e.key];
              if (!value) return; // let every other key behave natively

              const hasOption = Array.from(this.el.options).some((o) => o.value === value);
              if (!hasOption) return;

              // Stop the browser's native "jump to option starting with
              // this character" select behavior — we're fully driving the
              // value ourselves.
              e.preventDefault();

              this.el.value = value;
              // LiveView's phx-change listens for a real "change" event
              // bubbling up from the form.
              this.el.dispatchEvent(new Event("change", {bubbles: true}));

              // Close any open native dropdown before moving focus, or it
              // stays visibly open over the next board's select.
              this.el.blur();

              this.focusNextBoard();
            };

            this.el.addEventListener("keydown", this.onKeydown);
          },

          focusNextBoard() {
            const selects = Array.from(document.querySelectorAll("select[data-board-select]"));
            const index = selects.indexOf(this.el);
            if (index >= 0 && index < selects.length - 1) {
              const next = selects[index + 1];

              // Focusing normally makes the browser jump-scroll the next
              // select into view only once it's fully out of the viewport —
              // the screen sits still for several entries, then lurches
              // several rows at once. `preventScroll` stops that native
              // jump so we can drive a smooth, one-row-at-a-time scroll
              // ourselves below instead.
              next.focus({ preventScroll: true });

              const row = next.closest("tr") || next;
              row.scrollIntoView({ behavior: "smooth", block: "center" });
            }
          },

          destroyed() {
            this.el.removeEventListener("keydown", this.onKeydown);
            this.el.removeEventListener("mousedown", this.onMousedown);
          }
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".PrintMenu">
        // Consolidates a print button's variants behind a right-click
        // context menu instead of a row of separate buttons: left-click on
        // the anchor still opens the plain/default print in a new tab
        // (native <a target="_blank"> behavior, untouched); right-click
        // suppresses the browser's context menu and shows this small popup
        // built from the hidden ".print-menu-items" sibling's own <a> tags,
        // so each menu item is a real link with its own href/target/title —
        // no data-JSON to keep in sync with the markup.
        export default {
          mounted() {
            this.menu = this.el.querySelector(".print-menu-items");
            this.popup = null;

            this.onContextMenu = (e) => {
              e.preventDefault();
              this.openAt(e.clientX, e.clientY);
            };
            this.el.addEventListener("contextmenu", this.onContextMenu);

            this.onDocMousedown = (e) => {
              if (this.popup && !this.popup.contains(e.target)) this.close();
            };
            this.onDocKeydown = (e) => {
              if (e.key === "Escape") this.close();
            };
            document.addEventListener("mousedown", this.onDocMousedown);
            document.addEventListener("keydown", this.onDocKeydown);
          },

          openAt(x, y) {
            this.close();

            const popup = document.createElement("div");
            popup.className = "print-menu-popup";
            popup.style.left = `${x}px`;
            popup.style.top = `${y}px`;

            Array.from(this.menu.querySelectorAll("a")).forEach((link) => {
              const item = link.cloneNode(true);
              item.addEventListener("click", () => this.close());
              popup.appendChild(item);
            });

            document.body.appendChild(popup);
            this.popup = popup;
          },

          close() {
            if (this.popup) {
              this.popup.remove();
              this.popup = null;
            }
          },

          destroyed() {
            this.close();
            this.el.removeEventListener("contextmenu", this.onContextMenu);
            document.removeEventListener("mousedown", this.onDocMousedown);
            document.removeEventListener("keydown", this.onDocKeydown);
          }
        }
      </script>
    </Layouts.app>
    """
  end
end
