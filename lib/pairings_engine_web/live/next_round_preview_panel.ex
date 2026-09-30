defmodule PairingsEngineWeb.NextRoundPreviewPanel do
  @moduledoc """
  The "Preview next round" panel of the Pairings page
  (`PairingsEngineWeb.PairingsLive`) - see `PairingsEngine.NextRoundPreview`
  for what it works out.

  Its state is one assign, `:next_round_preview`, and this module owns it:
  `init/1` in the page's mount, `refresh/1` after each of its refreshes,
  and `handle_event/3`, `handle_info/2` and `handle_async/3` for the
  messages below. The page only forwards them.

  The work runs with `start_async/4` under `PairingsEngine.TaskSupervisor`,
  never in the page's process; a new start or closing the panel cancels a
  run still going. While the panel is open, every refresh compares the
  data's `NextRoundPreview.fingerprint/1` with the one the preview was
  worked out from, and when a result, a player or a setting changed it
  works the preview out again - `debounce_ms/0` after the last change, so
  a burst of results entered costs one run.
  """
  use PairingsEngineWeb, :html

  import Phoenix.LiveView, only: [connected?: 1, start_async: 4, cancel_async: 2]

  alias PairingsEngine.{NextRoundPreview, Tournaments}
  alias PairingsEngine.NextRoundPreview.Cache

  @async :next_round_preview
  @default_debounce_ms 1_500

  # How many outcomes must be paired before the time left is estimated.
  @eta_after 3

  @doc false
  def debounce_ms,
    do:
      Application.get_env(:pairings_engine, :next_round_preview_debounce_ms, @default_debounce_ms)

  @doc "The panel's state, closed."
  def init(socket) do
    Phoenix.Component.assign(socket, :next_round_preview, %{
      availability: :unavailable,
      open?: false,
      running?: false,
      # `%{done:, total:, eta_ms:}` while a run reports progress; `eta_ms`
      # once a few outcomes are done.
      progress: nil,
      started_at: nil,
      preview: nil,
      error: nil,
      # The fingerprint of the data the preview on screen (or the run in
      # progress) was worked out from.
      fingerprint: nil,
      # The data has changed since; a new run is due or under way.
      stale?: false,
      run: nil,
      debounce: nil
    })
  end

  @doc """
  After the page reloaded its data: whether the preview applies, and - while
  the panel is open - whether what it shows is still current.
  """
  def refresh(socket) do
    state = socket.assigns.next_round_preview

    socket =
      put_state(socket, availability: NextRoundPreview.availability(socket.assigns.tournament))

    cond do
      not state.open? or not connected?(socket) ->
        socket

      not match?({:available, _}, socket.assigns.next_round_preview.availability) ->
        socket |> cancel_async(@async) |> put_state(running?: false, run: nil, stale?: false)

      NextRoundPreview.fingerprint(socket.assigns.tournament.id) == state.fingerprint ->
        socket

      true ->
        schedule(socket)
    end
  end

  def handle_event("open", _params, socket) do
    socket = put_state(socket, open?: true, error: nil)

    if match?({:available, _}, socket.assigns.next_round_preview.availability),
      do: start_or_reuse(socket),
      else: socket
  end

  def handle_event("close", _params, socket) do
    socket
    |> cancel_async(@async)
    |> put_state(open?: false, running?: false, run: nil, progress: nil, stale?: false)
  end

  def handle_info({:recompute, token}, socket) do
    state = socket.assigns.next_round_preview

    if state.open? and state.debounce == token and
         match?({:available, _}, state.availability) do
      start_or_reuse(put_state(socket, debounce: nil))
    else
      socket
    end
  end

  # `NextRoundPreview.run/2` reports at most ten times a second.
  def handle_info({:progress, run, done, total}, socket) do
    state = socket.assigns.next_round_preview

    if state.run == run do
      elapsed = System.monotonic_time(:millisecond) - state.started_at

      eta_ms =
        if done >= @eta_after and done < total,
          do: div(elapsed * (total - done), done)

      put_state(socket, progress: %{done: done, total: total, eta_ms: eta_ms})
    else
      socket
    end
  end

  def handle_async({:ok, {run, result}}, socket) do
    if socket.assigns.next_round_preview.run == run do
      case result do
        {:ok, preview} ->
          put_state(socket, running?: false, run: nil, preview: preview, error: nil)

        {:error, reason} ->
          put_state(socket, running?: false, run: nil, preview: nil, error: reason)
      end
    else
      socket
    end
  end

  # Cancelled by a newer run or by closing the panel.
  def handle_async({:exit, {:shutdown, :cancel}}, socket), do: socket

  def handle_async({:exit, _reason}, socket) do
    put_state(socket, running?: false, run: nil, error: :crashed)
  end

  # A burst of changes - results entered one after the other - is one run,
  # `debounce_ms/0` after the last of them.
  defp schedule(socket) do
    case debounce_ms() do
      0 ->
        start_or_reuse(socket)

      ms ->
        token = make_ref()
        Process.send_after(self(), {:next_round_preview, {:recompute, token}}, ms)
        put_state(socket, debounce: token, stale?: true)
    end
  end

  defp start_or_reuse(socket) do
    id = socket.assigns.tournament.id
    fingerprint = NextRoundPreview.fingerprint(id)

    case Cache.get(id, fingerprint) do
      nil ->
        start(socket, fingerprint)

      preview ->
        socket
        |> cancel_async(@async)
        |> put_state(
          preview: preview,
          fingerprint: fingerprint,
          running?: false,
          run: nil,
          stale?: false,
          error: nil
        )
    end
  end

  defp start(socket, fingerprint) do
    id = socket.assigns.tournament.id
    page = self()
    run = make_ref()

    socket
    |> cancel_async(@async)
    |> put_state(
      running?: true,
      run: run,
      fingerprint: fingerprint,
      stale?: false,
      progress: nil,
      started_at: System.monotonic_time(:millisecond),
      error: nil
    )
    |> start_async(
      @async,
      fn ->
        progress = fn done, total ->
          send(page, {:next_round_preview, {:progress, run, done, total}})
        end

        result = runner().(Tournaments.get_tournament!(id), progress: progress)

        with {:ok, preview} <- result,
             do: Cache.put(id, preview.fingerprint, preview)

        {run, result}
      end,
      supervisor: PairingsEngine.TaskSupervisor
    )
  end

  # `NextRoundPreview.run/2`; a test may stand in for it to hold a run open.
  defp runner,
    do: Application.get_env(:pairings_engine, :next_round_preview_runner, &NextRoundPreview.run/2)

  defp put_state(socket, changes) do
    Phoenix.Component.update(socket, :next_round_preview, &Map.merge(&1, Map.new(changes)))
  end

  ## ---------- the panel ----------

  attr :state, :map, required: true
  attr :tournament, :map, required: true
  attr :show, :boolean, default: true

  def panel(assigns) do
    ~H"""
    <%= if @show do %>
      <%= cond do %>
        <% @state.open? -> %>
          <.open_panel state={@state} tournament={@tournament} />
        <% match?({:available, _}, @state.availability) -> %>
          <div id="next-round-preview-offer" class="nrp-offer">
            <button
              id="next-round-preview-open"
              type="button"
              class="pe-btn tonal"
              phx-click="next_round_preview_open"
            >
              <.icon name="hero-eye-micro" /> {gettext("Preview next round")}
            </button>
            
            <span class="hint">
              {ngettext(
                "1 game still open: see which boards of the next round are already certain.",
                "%{count} games still open: see which boards of the next round are already certain.",
                elem(@state.availability, 1)
              )}
            </span>
          </div>
        <% match?({:too_many, _}, @state.availability) -> %>
          <p id="next-round-preview-too-many" class="nrp-offer hint">
            <.icon name="hero-eye-slash-micro" /> {gettext(
              "%{count} games still open - the next-round preview is available when %{max} or fewer remain.",
              count: elem(@state.availability, 1),
              max: NextRoundPreview.max_open_games()
            )}
          </p>
        <% true -> %>
      <% end %>
    <% end %>
    """
  end

  attr :state, :map, required: true
  attr :tournament, :map, required: true

  defp open_panel(assigns) do
    assigns = assign(assigns, :preview, assigns.state.preview)

    ~H"""
    <section
      id="next-round-preview"
      class={["card nrp-panel", (@state.running? or @state.stale?) && "is-updating"]}
      aria-labelledby="next-round-preview-title"
      aria-busy={to_string(@state.running?)}
    >
      <header class="nrp-head">
        <h2 id="next-round-preview-title">
          {if @preview,
            do: gettext("Preview of round %{n}", n: @preview.next_round),
            else: gettext("Preview of the next round")}
        </h2>
        
        <span id="next-round-preview-label" class="badge nrp-badge">
          {gettext("Preview - nothing is saved")}
        </span>
        
        <div class="nrp-head-actions">
          <a
            :if={@preview && !@state.running? && !@state.stale?}
            id="next-round-preview-print"
            class="pe-btn"
            href={~p"/t/#{@tournament.id}/print/next-round-preview"}
            target="_blank"
          >
            <.icon name="hero-printer-micro" /> {gettext("Print fixed boards")}
          </a>
          
          <button
            id="next-round-preview-close"
            type="button"
            class="pe-btn"
            phx-click="next_round_preview_close"
          >
            {gettext("Close")}
          </button>
        </div>
      </header>
      
      <p class="hint nrp-explain">
        {gettext(
          "Worked out by pairing the next round for every possible result of the games still open, exactly as the real pairing will. Only the boards that come out the same whatever happens are certain. The round itself is paired as usual once the last result is in."
        )}
      </p>
      
      <%= cond do %>
        <% not match?({:available, _}, @state.availability) -> %>
          <p id="next-round-preview-done" class="nrp-status">
            {gettext("No preview needed: every result of the round is in, or too many are missing.")}
          </p>
        <% @state.running? -> %>
          <.progress_line progress={@state.progress} />
        <% @state.stale? -> %>
          <p id="next-round-preview-stale" class="nrp-status">
            <span class="nrp-spinner" aria-hidden="true"></span> {gettext(
              "A result or the field changed - updating…"
            )}
          </p>
        <% true -> %>
      <% end %>
      
      <p :if={@state.error} id="next-round-preview-error" class="error-note" role="alert">
        {error_text(@state.error)}
      </p>
      
      <.results
        :if={@preview && match?({:available, _}, @state.availability)}
        preview={@preview}
      />
    </section>
    """
  end

  attr :progress, :any, required: true

  defp progress_line(assigns) do
    ~H"""
    <div id="next-round-preview-progress" class="nrp-status nrp-progress" role="status">
      <%= case @progress do %>
        <% %{done: done, total: total, eta_ms: eta_ms} -> %>
          <progress id="next-round-preview-bar" max={total} value={done}>{done}/{total}</progress>
          <span id="next-round-preview-count">
            {gettext("Paired %{done} of %{total} variants", done: done, total: total)}
          </span>
          
          <span :if={eta_ms} id="next-round-preview-eta" class="hint">
            · {time_left(eta_ms)}
          </span>
        <% _ -> %>
          <progress id="next-round-preview-bar"></progress>
          <span>{gettext("Reading the tournament…")}</span>
      <% end %>
    </div>
    """
  end

  attr :preview, :map, required: true

  defp results(assigns) do
    ~H"""
    <div id="next-round-preview-results" class="nrp-results">
      <p id="next-round-preview-summary" class="nrp-summary">{summary(@preview)}</p>
      
      <p class="hint">
        {ngettext(
          "From %{outcomes} outcomes of 1 open game (%{games}).",
          "From %{outcomes} outcomes of %{count} open games (%{games}).",
          length(@preview.games),
          outcomes: @preview.outcomes,
          games: Enum.map_join(@preview.games, ", ", &gettext("board %{b}", b: &1.label))
        )}
      </p>
      
      <p :if={@preview.failed > 0} id="next-round-preview-failures" class="error-note">
        {ngettext(
          "In 1 outcome the round cannot be paired at all; it is left out of the comparison.",
          "In %{count} outcomes the round cannot be paired at all; they are left out of the comparison.",
          @preview.failed
        )}
      </p>
      
      <details :if={@preview.fixed != []} id="next-round-preview-fixed" class="nrp-group" open>
        <summary>
          <strong>{gettext("Fixed boards")}</strong>
          <span class="hint">{gettext("cards can go out")}</span>
        </summary>
        
        <table class="pe-table nrp-table">
          <thead>
            <tr>
              <th class="num">{gettext("Board")}</th>
              
              <th>{gettext("White")}</th>
              
              <th>{gettext("Black")}</th>
            </tr>
          </thead>
          
          <tbody>
            <tr :for={row <- @preview.fixed} id={"nrp-fixed-#{row.white}"}>
              <td class="num">{row.label}</td>
              
              <td>{name(@preview, row.white)}</td>
              
              <td>{name(@preview, row.black)}</td>
            </tr>
          </tbody>
        </table>
      </details>
      
      <details :if={@preview.shifting != []} id="next-round-preview-shifting" class="nrp-group">
        <summary>
          <strong>{gettext("Pair and colours fixed, board may shift")}</strong>
        </summary>
        
        <table class="pe-table nrp-table">
          <thead>
            <tr>
              <th class="num">{gettext("Boards")}</th>
              
              <th>{gettext("White")}</th>
              
              <th>{gettext("Black")}</th>
            </tr>
          </thead>
          
          <tbody>
            <tr :for={row <- @preview.shifting} id={"nrp-shifting-#{row.white}"}>
              <td class="num">{NextRoundPreview.label_ranges(row.labels)}</td>
              
              <td>{name(@preview, row.white)}</td>
              
              <td>{name(@preview, row.black)}</td>
            </tr>
          </tbody>
        </table>
      </details>
      
      <details
        :if={@preview.colours_open != []}
        id="next-round-preview-colours-open"
        class="nrp-group"
      >
        <summary><strong>{gettext("Pair fixed, colours open")}</strong></summary>
        
        <table class="pe-table nrp-table">
          <thead>
            <tr>
              <th class="num">{gettext("Boards")}</th>
              
              <th>{gettext("Players")}</th>
            </tr>
          </thead>
          
          <tbody>
            <tr :for={row <- @preview.colours_open} id={"nrp-colours-#{hd(row.players)}"}>
              <td class="num">{NextRoundPreview.label_ranges(row.labels)}</td>
              
              <td>{Enum.map_join(row.players, " – ", &name(@preview, &1))}</td>
            </tr>
          </tbody>
        </table>
      </details>
      
      <details :if={@preview.open != []} id="next-round-preview-open-players" class="nrp-group">
        <summary><strong>{gettext("Open - depends on the results")}</strong></summary>
        
        <table class="pe-table nrp-table">
          <thead>
            <tr>
              <th>{gettext("Player")}</th>
              
              <th>{gettext("Could meet")}</th>
              
              <th>{gettext("Decided by")}</th>
            </tr>
          </thead>
          
          <tbody>
            <tr
              :for={row <- Enum.sort_by(@preview.open, &name(@preview, &1.player))}
              id={"nrp-open-#{row.player}"}
            >
              <td>{name(@preview, row.player)}</td>
              
              <td class="nrp-wrap">{opponents(@preview, row.opponents)}</td>
              
              <td>{games(@preview, row.depends_on)}</td>
            </tr>
          </tbody>
        </table>
      </details>
      
      <p :if={@preview.bye.status != :none} id="next-round-preview-bye" class="nrp-bye">
        <%= if @preview.bye.status == :fixed do %>
          {gettext("Bye: %{name}, whatever the results.", name: name(@preview, @preview.bye.holder))}
        <% else %>
          {gettext("Bye: open - %{names} (decided by %{games}).",
            names: Enum.map_join(@preview.bye.candidates, ", ", &name(@preview, &1)),
            games: games(@preview, @preview.bye.depends_on)
          )}
        <% end %>
      </p>
    </div>
    """
  end

  @doc """
  The one-line summary, e.g. "Boards 1–38 fixed · 14 pairs fixed, board may
  shift · 12 players open".
  """
  def summary(preview) do
    [
      preview.fixed != [] &&
        ngettext("Board %{boards} fixed", "Boards %{boards} fixed", length(preview.fixed),
          boards: NextRoundPreview.label_ranges(Enum.map(preview.fixed, & &1.label))
        ),
      preview.shifting != [] &&
        ngettext(
          "1 pair fixed, board may shift",
          "%{count} pairs fixed, board may shift",
          length(preview.shifting)
        ),
      preview.colours_open != [] &&
        ngettext(
          "1 pair fixed, colours open",
          "%{count} pairs fixed, colours open",
          length(preview.colours_open)
        ),
      preview.open != [] &&
        ngettext("1 player open", "%{count} players open", length(preview.open)),
      bye_summary(preview)
    ]
    |> Enum.filter(&is_binary/1)
    |> case do
      [] -> gettext("Nothing is certain yet.")
      parts -> Enum.join(parts, " · ")
    end
  end

  defp bye_summary(%{bye: %{status: :fixed}}), do: gettext("bye fixed")
  defp bye_summary(%{bye: %{status: :open}}), do: gettext("bye open")
  defp bye_summary(_preview), do: nil

  defp name(preview, id) do
    case Map.get(preview.players, id) do
      %{name: name} -> name
      nil -> "?"
    end
  end

  defp time_left(ms) when ms < 60_000,
    do: gettext("about %{s} s left", s: max(1, div(ms + 999, 1000)))

  defp time_left(ms), do: gettext("about %{m} min left", m: div(ms + 59_999, 60_000))

  @shown_opponents 6

  defp opponents(preview, opponents) do
    {shown, rest} =
      opponents
      |> Enum.map(fn
        :bye -> gettext("the bye")
        nil -> gettext("no board")
        id -> name(preview, id)
      end)
      |> Enum.sort()
      |> Enum.split(@shown_opponents)

    case rest do
      [] -> Enum.join(shown, ", ")
      rest -> Enum.join(shown, ", ") <> " " <> gettext("and %{count} more", count: length(rest))
    end
  end

  defp games(_preview, []), do: "-"

  defp games(preview, indices) do
    Enum.map_join(indices, ", ", fn j ->
      gettext("board %{b}", b: Enum.at(preview.games, j).label)
    end)
  end

  defp error_text(:crashed), do: gettext("The preview could not be worked out.")

  defp error_text({:too_many, count}),
    do:
      gettext(
        "%{count} games still open - the next-round preview is available when %{max} or fewer remain.",
        count: count,
        max: NextRoundPreview.max_open_games()
      )

  defp error_text({:all_failed, reason}),
    do:
      gettext("The next round cannot be paired in any outcome: %{reason}",
        reason: PairingsEngineWeb.SettingsSupport.error_text(reason)
      )

  defp error_text(reason) when is_atom(reason),
    do: gettext("The preview is not available for this round.")

  defp error_text(reason), do: PairingsEngineWeb.SettingsSupport.error_text(reason)
end
