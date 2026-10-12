defmodule PairingsEngineWeb.BoardGameLive do
  @moduledoc """
  One game as a board in the hall reported it (`/t/:id/games/:game`, reached
  from the board column on the Pairings page): the moves, the clocks, what
  the board made of the result beside what the arbiter entered, and the PGN.

  Read-only. There is no button here that takes the board's result over:
  results are entered on the Pairings page, by a person, and that is the
  design and not an omission (`PairingsEngine.BoardLink`).

  `:game` is the pairing's `game_uid`, so a link to a game survives a
  restore point, which a row id does not.
  """
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.{BoardLink, PairingDisplay, PgnExport, Tournaments}

  @impl true
  def mount(%{"id" => id, "game" => game_uid}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
      BoardLink.subscribe(tournament.id)
    end

    socket = assign(socket, tournament: tournament, game_uid: game_uid)

    case load(socket) do
      {:ok, socket} ->
        {:ok, socket}

      :gone ->
        {:ok,
         socket
         |> put_flash(:error, gettext("That game is no longer in this tournament."))
         |> push_navigate(to: ~p"/t/#{tournament.id}/pairings")}
    end
  end

  defp load(socket) do
    %{tournament: tournament, game_uid: game_uid} = socket.assigns

    case BoardLink.get_pairing(tournament.id, game_uid) do
      nil ->
        :gone

      pairing ->
        game = BoardLink.get_game(tournament.id, game_uid)

        {:ok,
         assign(socket,
           pairing: pairing,
           game: game,
           comparison: BoardLink.compare(pairing.result, game),
           pgn: PgnExport.export(tournament, pairing.round.number, moves: true, game: game_uid),
           page_title:
             "#{tournament.name} · #{pairing.white_player.name} - #{pairing.black_player.name}"
         )}
    end
  end

  @impl true
  def handle_info({:board_game, _id, game_uid, _kind}, socket) do
    if game_uid == socket.assigns.game_uid, do: reload(socket), else: {:noreply, socket}
  end

  def handle_info({:tournament_changed, _id, hint}, socket) when hint != :explanation,
    do: reload(socket)

  def handle_info(_message, socket), do: {:noreply, socket}

  defp reload(socket) do
    with %{} = tournament <-
           Tournaments.get_authorized_tournament(
             socket.assigns.current_scope,
             socket.assigns.tournament.id
           ),
         {:ok, socket} <- load(assign(socket, tournament: tournament)) do
      {:noreply, socket}
    else
      _gone -> {:noreply, push_navigate(socket, to: ~p"/")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      publish_status={assigns[:publish_status]}
      update_notice={assigns[:update_notice]}
      fide_notice={assigns[:fide_notice]}
      flash={@flash}
      current_path={assigns[:current_path]}
      current_scope={@current_scope}
      tournament={@tournament}
      active="pairings"
    >
      <div class="page-header">
        <div>
          <h1 id="board-game-title">
            {@pairing.white_player.name} - {@pairing.black_player.name}
          </h1>
          <p class="subtitle" style="margin: 0">
            {gettext("Round %{round}, board %{board}",
              round: @pairing.round.number,
              board: PairingDisplay.board_label(@pairing)
            )}
          </p>
        </div>

        <.link
          id="board-game-back"
          class="pe-btn"
          navigate={~p"/t/#{@tournament.id}/pairings?round=#{@pairing.round.number}"}
        >
          {gettext("Back to the pairings")}
        </.link>
      </div>

      <div class="card" id="board-game-results">
        <h2>{gettext("Result")}</h2>

        <dl class="board-game-facts">
          <dt>{gettext("Entered by the arbiter")}</dt>
          <dd id="board-game-arbiter">
            {if @pairing.result == "", do: gettext("not yet"), else: @pairing.result}
          </dd>

          <dt>{gettext("Seen by the board")}</dt>
          <dd id="board-game-board" class={[@comparison == :mismatch && "board-mismatch-text"]}>
            <%= cond do %>
              <% is_nil(@game) -> %>
                {gettext("nothing reported")}
              <% @game.result -> %>
                {@game.result}
              <% @game.status == "finished" -> %>
                {gettext("finished, no result seen")}
              <% @game.status == "waiting" -> %>
                {gettext("not started")}
              <% true -> %>
                {gettext("in progress")}
            <% end %>
          </dd>
        </dl>

        <p :if={@comparison == :mismatch} id="board-game-mismatch" class="error-note" role="alert">
          <.icon name="hero-exclamation-triangle" class="size-4" />
          {gettext(
            "The board and the entered result differ. Nothing is changed for you: check the scoresheets, and correct the result on the Pairings page if it is the one that is wrong."
          )}
        </p>

        <p
          :if={@game && (@game.reconstructed > 0 or @game.guessed > 0)}
          id="board-game-doubt"
          class="hint"
        >
          {gettext(
            "The box worked out %{reconstructed} of these moves after the fact and guessed %{guessed}. A guessed move is the box's best reading of an unclear board, not something it saw.",
            reconstructed: @game.reconstructed,
            guessed: @game.guessed
          )}
        </p>
      </div>

      <div :if={@game} class="card" id="board-game-moves-card">
        <h2>{gettext("Moves")}</h2>

        <p :if={@game.moves == []} class="hint" style="margin-top: 0">
          {gettext("No moves reported.")}
        </p>

        <ol :if={@game.moves != []} class="board-game-moves" id="board-game-moves">
          <li :for={{pair, n} <- @game.moves |> Enum.chunk_every(2) |> Enum.with_index(1)}>
            <span class="board-game-no">{n}.</span>
            <span :for={move <- pair} class="board-game-move">{move}</span>
          </li>
        </ol>

        <p :if={@game.white_ms || @game.black_ms} class="hint" id="board-game-clocks">
          {gettext("Clocks at the last report: White %{white}, Black %{black}.",
            white: clock(@game.white_ms),
            black: clock(@game.black_ms)
          )}
        </p>

        <p :if={@game.reported_at} class="hint" style="margin-bottom: 0">
          {gettext("Last report %{at} UTC.",
            at: Calendar.strftime(@game.reported_at, "%d-%m-%Y %H:%M:%S")
          )}
        </p>
      </div>

      <div class="card" id="board-game-pgn-card">
        <h2>PGN</h2>

        <p class="hint" style="margin-top: 0">
          {gettext(
            "Headers from the tournament; the result is the one entered here, or * until there is one."
          )}
        </p>

        <pre id="board-game-pgn" class="board-game-pgn">{@pgn}</pre>

        <p style="margin-bottom: 0">
          <.link
            id="board-game-download"
            class="pe-btn primary"
            href={
              ~p"/t/#{@tournament.id}/export/pgn?moves=1&round=#{@pairing.round.number}&game=#{@game_uid}"
            }
          >
            {gettext("Download PGN")}
          </.link>

          <.link
            :if={@game && @game.pgn}
            id="board-game-download-box"
            class="pe-btn"
            href={~p"/t/#{@tournament.id}/export/pgn?source=box&game=#{@game_uid}"}
          >
            {gettext("The box's own PGN")}
          </.link>
        </p>
      </div>
    </Layouts.app>
    """
  end

  defp clock(nil), do: "-"

  defp clock(ms) do
    total = div(ms, 1000)

    "#{div(total, 3600)}:#{pad(rem(div(total, 60), 60))}:#{pad(rem(total, 60))}"
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
