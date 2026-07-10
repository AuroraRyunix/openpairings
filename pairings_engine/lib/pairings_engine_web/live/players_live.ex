defmodule PairingsEngineWeb.PlayersLive do
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.{Tournaments, Fide, Standings, PlayerStats}
  alias PairingsEngine.Tournaments.Player

  # Bio columns of the player grid; which ones show is up to the user (Display panel).
  @bio_columns [
    {"title", "Title", false},
    {"sex", "Sex", false},
    {"birth_year", "Birth", true},
    {"federation", "Country", false},
    {"national_id", "Id Nat", true},
    {"fide_id", "Id FIDE", true},
    {"fide_rating", "Elo FIDE", true},
    {"national_rating", "Elo Nat", true},
    {"club", "Club", false},
    {"status", "Status", false}
  ]

  # SWAR-style computed columns, sourced from Standings.grid_standings/1.
  @grid_columns [
    {"cl", "Cl", true},
    {"nr", "Nr", true},
    {"cat", "Cat", false},
    {"games", "Ga", true},
    {"pts", "Pts", true},
    {"perf", "Perf", true},
    {"buch", "Buch", true},
    {"bc1", "B C1", true},
    {"sb", "S.B.", true},
    {"prog", "Prog.", true},
    {"diren", "DirEn", true}
  ]

  @all_columns @bio_columns ++ @grid_columns
  @default_visible ~w(title birth_year federation fide_id fide_rating national_rating club) ++
                     ~w(cl games pts)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_user_tournament!(socket.assigns.current_scope, id)

    {:ok,
     socket
     |> assign(
       tournament: tournament,
       page_title: "#{tournament.name} · Players",
       adding: false,
       error: nil,
       query: "",
       results: [],
       form_values: %{},
       visible: @default_visible
     )
     |> assign_players()}
  end

  defp assign_players(socket) do
    tournament = socket.assigns.tournament

    entries =
      tournament
      |> Standings.grid_standings()
      |> build_grid(tournament)
      |> Enum.sort_by(fn e -> {-Player.rating(e.player), e.player.name} end)

    assign(socket, :players, entries)
  end

  # Attaches a `:grid` map of the SWAR-style computed columns to each
  # standings entry, keyed by the column key used in @grid_columns.
  defp build_grid(entries, tournament) do
    players_by_id = Map.new(entries, &{&1.player.id, &1.player})
    current_year = Date.utc_today().year

    Enum.map(entries, fn entry ->
      played_games = Enum.filter(entry.games, & &1.played)

      opponent_ratings =
        played_games
        |> Enum.map(&Map.get(players_by_id, &1.opponent_id))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&Player.rating/1)

      wins = Enum.count(played_games, &(&1.points >= tournament.points_win))
      losses = Enum.count(played_games, &(&1.points <= tournament.points_loss))

      grid = %{
        "cl" => entry.rank,
        "nr" => entry.player.pairing_number,
        "cat" => PlayerStats.category(entry.player.birth_year, current_year),
        "games" => length(played_games),
        "pts" => entry.points,
        "perf" => PlayerStats.performance(opponent_ratings, wins, losses),
        "buch" => Map.get(entry.tiebreaks, "BH"),
        "bc1" => Map.get(entry.tiebreaks, "BHC1"),
        "sb" => Map.get(entry.tiebreaks, "SB"),
        "prog" => Map.get(entry.tiebreaks, "PS"),
        "diren" => Map.get(entry.tiebreaks, "DE", 0.0)
      }

      Map.put(entry, :grid, grid)
    end)
  end

  @impl true
  def handle_event("add", _params, socket), do: {:noreply, assign(socket, adding: true)}

  def handle_event("done", _params, socket) do
    {:noreply, assign(socket, adding: false, error: nil, form_values: %{}, query: "", results: [])}
  end

  # Sent by the ColumnPrefs JS hook after reading localStorage.
  def handle_event("columns_loaded", %{"columns" => columns}, socket) when is_list(columns) do
    {:noreply, assign(socket, visible: columns)}
  end

  def handle_event("columns_loaded", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_column", %{"key" => key}, socket) do
    visible = socket.assigns.visible

    visible =
      if key in visible, do: List.delete(visible, key), else: visible ++ [key]

    {:noreply,
     socket
     |> assign(visible: visible)
     |> push_event("store_columns", %{columns: visible})}
  end

  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, assign(socket, query: q, results: Fide.search(q))}
  end

  def handle_event("pick", %{"fide-id" => fide_id}, socket) do
    case Enum.find(socket.assigns.results, &(&1.fide_id == String.to_integer(fide_id))) do
      nil ->
        {:noreply, socket}

      fp ->
        {:noreply,
         assign(socket,
           query: "",
           results: [],
           form_values: %{
             "name" => fp.name,
             "title" => fp.title,
             "fide_id" => fp.fide_id,
             "fide_rating" => fp.standard_rating,
             "federation" => fp.federation,
             "birth_year" => fp.birth_year,
             "sex" => fp.sex
           }
         )}
    end
  end

  def handle_event("save", %{"player" => params}, socket) do
    case Tournaments.create_player(socket.assigns.tournament.id, params) do
      {:ok, _player} ->
        {:noreply, socket |> assign(error: nil, form_values: %{}) |> assign_players()}

      {:error, :duplicate_fide_id} ->
        {:noreply, assign(socket, error: "A player with this FIDE ID is already registered")}

      {:error, changeset} ->
        {:noreply, assign(socket, error: error_text(changeset), form_values: params)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    id |> Tournaments.get_player!() |> Tournaments.delete_player()
    {:noreply, assign_players(socket)}
  end

  defp error_text(changeset) do
    Enum.map_join(changeset.errors, ", ", fn {field, {msg, _}} -> "#{field} #{msg}" end)
  end

  defp all_columns, do: @all_columns

  defp cell(entry, "status"), do: entry.player.status

  defp cell(entry, key) when key in ~w(title sex birth_year federation national_id fide_id
                                        fide_rating national_rating club) do
    case Map.get(entry.player, String.to_existing_atom(key)) do
      value when value in [nil, "", 0] -> "—"
      value -> value
    end
  end

  # Computed (SWAR-style) columns, sourced from the entry's :grid map built in
  # build_grid/2. "diren" (Direct Encounter) shows "—" instead of a bare 0,
  # since 0 there means "not applicable" rather than an actual value.
  defp cell(entry, "nr"), do: format_num(entry.grid["nr"])
  defp cell(entry, "cat") do
    case entry.grid["cat"] do
      "" -> "—"
      value -> value
    end
  end
  defp cell(entry, "perf"), do: format_num(entry.grid["perf"])
  defp cell(entry, "diren") do
    case entry.grid["diren"] do
      value when value in [nil, 0, 0.0] -> "—"
      value -> format_num(value)
    end
  end
  defp cell(entry, key) when key in ~w(cl games pts buch bc1 sb prog) do
    format_num(entry.grid[key])
  end

  # Integers render as-is; floats drop a trailing ".0" and trim to the
  # decimals actually present (6.5, 24.25, but zero always shows as "0").
  defp format_num(nil), do: "—"
  defp format_num(n) when is_integer(n), do: Integer.to_string(n)

  defp format_num(n) when is_float(n) do
    if n == Float.round(n, 0) do
      n |> trunc() |> Integer.to_string()
    else
      n
      |> :erlang.float_to_binary(decimals: 2)
      |> String.trim_trailing("0")
      |> String.trim_trailing(".")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} tournament={@tournament} active="players">
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">
            {length(@players)} player{if length(@players) != 1, do: "s"} registered
          </p>
        </div>
        <button :if={!@adding} class="pe-btn primary" phx-click="add">Add player</button>
      </div>

      <form :if={@adding} class="card" phx-submit="save">
        <h2>Add player</h2>

        <div class="field search-wrap">
          <span style="display:block;font-size:13px;font-weight:600;color:var(--text-soft);margin-bottom:4px">
            Search the FIDE database (name or FIDE ID)
          </span>
          <input
            type="text"
            name="q"
            value={@query}
            phx-change="search"
            phx-debounce="250"
            autocomplete="off"
            placeholder="Start typing a last name… e.g. Carlsen"
            class="pe-input"
          />
          <div :if={@results != []} class="search-results">
            <button
              :for={fp <- @results}
              type="button"
              phx-click="pick"
              phx-value-fide-id={fp.fide_id}
            >
              <span>{if fp.title != "", do: "#{fp.title} "}{fp.name}</span>
              <span class="meta">
                {fp.federation} · {fp.standard_rating || "unrated"} · {fp.birth_year || "—"}
              </span>
            </button>
          </div>
        </div>
        <p class="hint">…or fill the details in by hand below.</p>

        <div class="form-grid">
          <label class="field">
            <span>Full name *</span>
            <input name="player[name]" value={@form_values["name"]} placeholder="Lastname, Firstname" />
          </label>
          <label class="field">
            <span>Title</span>
            <select name="player[title]">
              <option value="">—</option>
              <option
                :for={t <- ~w(GM IM FM CM WGM WIM WFM WCM)}
                value={t}
                selected={@form_values["title"] == t}
              >
                {t}
              </option>
            </select>
          </label>
          <label class="field">
            <span>FIDE ID</span>
            <input name="player[fide_id]" value={@form_values["fide_id"]} />
          </label>
          <label class="field">
            <span>FIDE rating</span>
            <input type="number" name="player[fide_rating]" value={@form_values["fide_rating"]} />
          </label>
          <label class="field">
            <span>National ID</span>
            <input name="player[national_id]" value={@form_values["national_id"]} />
          </label>
          <label class="field">
            <span>National rating</span>
            <input type="number" name="player[national_rating]" value={@form_values["national_rating"]} />
          </label>
          <label class="field">
            <span>Federation</span>
            <input name="player[federation]" value={@form_values["federation"]} placeholder="BEL" />
          </label>
          <label class="field">
            <span>Birth year</span>
            <input type="number" name="player[birth_year]" value={@form_values["birth_year"]} />
          </label>
          <label class="field">
            <span>Club</span>
            <input name="player[club]" value={@form_values["club"]} />
          </label>
          <input type="hidden" name="player[sex]" value={@form_values["sex"]} />
        </div>
        <p :if={@error} class="error-note">{@error}</p>
        <div class="actions">
          <button type="submit" class="pe-btn primary">Add player</button>
          <button type="button" class="pe-btn" phx-click="done">Done</button>
        </div>
      </form>

      <div :if={@players == []} class="card empty">
        <p><strong>No players registered yet.</strong></p>
        <p>Add players by searching the FIDE database, or enter them by hand.</p>
      </div>

      <div :if={@players != []} class="split" id="players-grid" phx-hook="ColumnPrefs">
        <div class="card table-card split-main">
          <table class="pe-table">
            <thead>
              <tr>
                <th class="num">#</th>
                <th>Name</th>
                <th
                  :for={{key, label, num} <- all_columns()}
                  :if={key in @visible}
                  class={num && "num"}
                >
                  {label}
                </th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{p, i} <- Enum.with_index(@players, 1)}>
                <td class="num">{i}</td>
                <td><strong>{p.player.name}</strong></td>
                <td
                  :for={{key, _label, num} <- all_columns()}
                  :if={key in @visible}
                  class={num && "num"}
                >
                  {cell(p, key)}
                </td>
                <td style="text-align: right">
                  <button
                    class="pe-btn danger-link"
                    phx-click="delete"
                    phx-value-id={p.player.id}
                    data-confirm={"Remove #{p.player.name} from the tournament?"}
                  >
                    Remove
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <aside class="card display-panel">
          <h2>Display</h2>
          <label :for={{key, label, _num} <- all_columns()} class="check">
            <input
              type="checkbox"
              checked={key in @visible}
              phx-click="toggle_column"
              phx-value-key={key}
            />
            {label}
          </label>
        </aside>
      </div>
    </Layouts.app>
    """
  end
end
