defmodule PairingsEngineWeb.PlayersLive do
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.{
    Tournaments,
    Fide,
    Kbsb,
    Standings,
    PlayerStats,
    PlayerCard,
    RatingRefresh
  }

  alias PairingsEngine.Tournaments.Player
  alias PairingsEngine.Tournaments.Tournament
  alias PairingsEngine.Kbsb.KbsbPlayer

  @titles ~w(GM IM FM CM WGM WIM WFM WCM)

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
    {"status", "Status", false},
    {"fixed_board", "Table", true}
  ]

  # SWAR-style computed columns, sourced from Standings.grid_standings/1.
  @grid_columns [
    {"cl", "Cl", true},
    {"nr", "Nr", true},
    {"cat", "Cat", false},
    {"games", "Ga", true},
    {"pts", "Pts", true},
    {"perf", "Perf", true},
    {"we", "We", true},
    {"wmwe", "W-We", true},
    {"buch", "Buch", true},
    {"bc1", "B C1", true},
    {"sb", "S.B.", true},
    {"prog", "Prog.", true},
    {"diren", "DirEn", true},
    {"aff", "Aff.", false},
    {"pr", "Pr.", false},
    {"paid", "Paid", false},
    {"xtpts", "XtPts", true},
    {"ptot", "P.Tot.", true}
  ]

  @all_columns @bio_columns ++ @grid_columns
  @default_visible ~w(title birth_year federation fide_id fide_rating national_rating club) ++
                     ~w(cl games pts xtpts ptot)

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
       page_title: "#{tournament.name} · Players",
       adding: false,
       error: nil,
       query: "",
       results: [],
       form_values: %{},
       visible: @default_visible,
       editing_player: nil,
       edit_form: %{},
       edit_error: nil,
       card_player_id: nil,
       titles: @titles,
       rating_refresh: nil,
       setup_complete: Tournament.setup_complete?(tournament)
     )
     |> assign_players()}
  end

  # Another user (or another tab) changed this tournament's data — reload
  # the players list and the tournament itself, but leave any open
  # modal/form (add-player form, edit-player modal, players card) alone so
  # we don't clobber whatever the user is mid-typing there.
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
        {:noreply,
         socket
         |> assign(tournament: tournament, setup_complete: Tournament.setup_complete?(tournament))
         |> assign_players()}
    end
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

      # FIDE expected score (We / W−We, Table 8.1.2): only games against a
      # rated opponent count, per Article 8.3 — mirrors `opponent_ratings`
      # above but drops unrated (rating <= 0) opponents, since the table has
      # no defined probability against "no rating".
      rated_games =
        Enum.filter(played_games, fn g ->
          case Map.get(players_by_id, g.opponent_id) do
            nil -> false
            opp -> Player.rating(opp) > 0
          end
        end)

      own_rating = Player.rating(entry.player)

      rated_opponent_ratings =
        Enum.map(rated_games, &Player.rating(Map.get(players_by_id, &1.opponent_id)))

      we = PlayerStats.we(own_rating, rated_opponent_ratings)
      w_counted = rated_games |> Enum.map(& &1.points) |> Enum.sum()

      grid = %{
        "cl" => entry.rank,
        "nr" => entry.player.pairing_number,
        "cat" => PlayerStats.category(entry.player.birth_year, current_year),
        "games" => length(played_games),
        "pts" => entry.points,
        "perf" => PlayerStats.performance(opponent_ratings, wins, losses),
        "we" => we,
        "wmwe" => PlayerStats.w_minus_we(w_counted, we),
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
  def handle_event("add", _params, socket) do
    if Tournament.setup_complete?(socket.assigns.tournament) do
      {:noreply, assign(socket, adding: true)}
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         "Finish the tournament setup — fill in the name, start date and number of rounds in Settings before adding players."
       )}
    end
  end

  def handle_event("done", _params, socket) do
    {:noreply,
     assign(socket, adding: false, error: nil, form_values: %{}, query: "", results: [])}
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
        base = %{
          "name" => fp.name,
          "title" => fp.title,
          "fide_id" => fp.fide_id,
          "fide_rating" => fp.standard_rating,
          "federation" => fp.federation,
          "birth_year" => fp.birth_year,
          "sex" => fp.sex
        }

        {:noreply,
         assign(socket,
           query: "",
           results: [],
           form_values: merge_kbsb_by_fide_id(base, fp.fide_id)
         )}
    end
  end

  # Mirrors the FIDE add-form's "pick" autofill, but triggered by typing/
  # leaving the National ID field instead of picking from a search list —
  # KBSB has no fuzzy name search wired into the add form, only exact
  # national-id lookups.
  def handle_event("lookup_kbsb_add", %{"player" => %{"national_id" => national_id}}, socket) do
    case Kbsb.find_by_national_id(national_id) do
      nil ->
        {:noreply, socket}

      kp ->
        merged =
          socket.assigns.form_values
          |> Map.merge(%{
            "national_id" => kp.national_id,
            "national_rating" => kp.national_rating,
            "federation" => kp.federation,
            "club" => kp.club_name,
            "birth_year" => kp.birth_year
          })
          |> put_if_blank("name", KbsbPlayer.full_name(kp))
          |> put_if_blank("fide_id", kp.fide_id)

        {:noreply, assign(socket, form_values: merged)}
    end
  end

  def handle_event("lookup_kbsb_add", _params, socket), do: {:noreply, socket}

  def handle_event("save", %{"player" => params}, socket) do
    if not Tournament.setup_complete?(socket.assigns.tournament) do
      {:noreply,
       put_flash(
         socket,
         :error,
         "Finish the tournament setup — fill in the name, start date and number of rounds in Settings before adding players."
       )}
    else
      do_save(socket, params)
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    id |> Tournaments.get_player!() |> Tournaments.delete_player()
    {:noreply, assign_players(socket)}
  end

  ## ---------- Bulk rating refresh (FIDE/KBSB) ----------

  def handle_event("open_rating_refresh", _params, socket) do
    summary = RatingRefresh.dry_run(socket.assigns.tournament)
    {:noreply, assign(socket, rating_refresh: summary)}
  end

  def handle_event("close_rating_refresh", _params, socket) do
    {:noreply, assign(socket, rating_refresh: nil)}
  end

  def handle_event("apply_rating_refresh", _params, socket) do
    proposals = (socket.assigns.rating_refresh || %{proposals: []}).proposals

    case RatingRefresh.apply(socket.assigns.tournament, proposals) do
      {:ok, _players} ->
        {:noreply, socket |> assign(rating_refresh: nil) |> assign_players()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not apply the rating refresh")}
    end
  end

  ## ---------- Player registration dialog (double-click a row) ----------

  def handle_event("edit_player", %{"id" => id}, socket) do
    player = Tournaments.get_player!(id)

    {:noreply,
     assign(socket, editing_player: player, edit_form: player_to_form(player), edit_error: nil)}
  end

  def handle_event("close_edit", _params, socket) do
    {:noreply, assign(socket, editing_player: nil, edit_form: %{}, edit_error: nil)}
  end

  # Mirrors SWAR's "Rafraichir": re-looks-up the player in the local FIDE
  # copy (by FIDE ID if the form has one, by name otherwise) and refills
  # rating/title/federation/birth year from the match, if any.
  def handle_event("refresh_edit_fide", _params, socket) do
    form = socket.assigns.edit_form

    query =
      case Map.get(form, "fide_id") do
        v when v in [nil, ""] -> Map.get(form, "name", "")
        v -> to_string(v)
      end

    case Fide.search(query) do
      [fp | _] ->
        merged =
          Map.merge(form, %{
            "title" => fp.title,
            "fide_id" => fp.fide_id,
            "fide_rating" => fp.standard_rating,
            "federation" => fp.federation,
            "birth_year" => fp.birth_year
          })

        {:noreply, assign(socket, edit_form: merged, edit_error: nil)}

      [] ->
        {:noreply, assign(socket, edit_error: "No matching FIDE player found")}
    end
  end

  # KBSB counterpart of refresh_edit_fide/2: looked up by National ID only
  # (KBSB has no FIDE-style name search), refills national rating/club/
  # federation/birth year, and the FIDE id too if the form doesn't already
  # have one — the FIDE list stays the source of truth for that field.
  def handle_event("refresh_edit_kbsb", _params, socket) do
    form = socket.assigns.edit_form
    national_id = form |> Map.get("national_id", "") |> to_string() |> String.trim()

    cond do
      national_id == "" ->
        {:noreply, assign(socket, edit_error: "Enter a National ID first")}

      kp = Kbsb.find_by_national_id(national_id) ->
        merged =
          form
          |> Map.merge(%{
            "national_rating" => kp.national_rating,
            "federation" => kp.federation,
            "club" => kp.club_name,
            "club_number" => kp.club_number,
            "birth_year" => kp.birth_year
          })
          |> put_if_blank("fide_id", kp.fide_id)

        {:noreply, assign(socket, edit_form: merged, edit_error: nil)}

      true ->
        {:noreply, assign(socket, edit_error: "No matching KBSB player found")}
    end
  end

  def handle_event("save_player", %{"player" => params}, socket) do
    case Tournaments.update_player(socket.assigns.editing_player, params) do
      {:ok, _player} ->
        {:noreply,
         socket
         |> assign(editing_player: nil, edit_form: %{}, edit_error: nil)
         |> assign_players()}

      {:error, changeset} ->
        {:noreply, assign(socket, edit_error: error_text(changeset), edit_form: params)}
    end
  end

  ## ---------- Players Card (right-click a row) ----------

  def handle_event("show_card", %{"id" => id}, socket) do
    {:noreply, assign(socket, card_player_id: String.to_integer(id))}
  end

  def handle_event("close_card", _params, socket) do
    {:noreply, assign(socket, card_player_id: nil)}
  end

  def handle_event("card_prev", _params, socket) do
    {:noreply,
     assign(socket,
       card_player_id:
         adjacent_player_id(socket.assigns.players, socket.assigns.card_player_id, -1)
     )}
  end

  def handle_event("card_next", _params, socket) do
    {:noreply,
     assign(socket,
       card_player_id:
         adjacent_player_id(socket.assigns.players, socket.assigns.card_player_id, 1)
     )}
  end

  defp do_save(socket, params) do
    case Tournaments.create_player(socket.assigns.tournament.id, params) do
      {:ok, _player} ->
        {:noreply, socket |> assign(error: nil, form_values: %{}) |> assign_players()}

      {:error, :duplicate_fide_id} ->
        {:noreply, assign(socket, error: "A player with this FIDE ID is already registered")}

      {:error, changeset} ->
        {:noreply, assign(socket, error: error_text(changeset), form_values: params)}
    end
  end

  defp adjacent_player_id(players, current_id, delta) do
    ids = Enum.map(players, & &1.player.id)

    case Enum.find_index(ids, &(&1 == current_id)) do
      nil -> current_id
      idx -> Enum.at(ids, rem(idx + delta + length(ids), length(ids)))
    end
  end

  defp player_to_form(p) do
    %{
      "national_id" => p.national_id,
      "name" => p.name,
      "birth_year" => blank_or(p.birth_year),
      "sex" => p.sex,
      "club" => p.club,
      "club_number" => blank_or(p.club_number),
      "federation" => p.federation,
      "national_rating" => blank_or(p.national_rating),
      "title" => p.title,
      "fide_id" => blank_or(p.fide_id),
      "fide_rating" => blank_or(p.fide_rating),
      "category" => p.category,
      "paid" => p.paid,
      "affiliated" => p.affiliated,
      "absent" => p.absent,
      "forfeit" => p.forfeit,
      "fixed_board" => blank_or(p.fixed_board),
      "absent_rounds" => p.absent_rounds,
      "extra_points" => p.extra_points
    }
  end

  defp blank_or(nil), do: ""
  defp blank_or(value), do: value

  # Picking a FIDE result also enriches the form with the matching KBSB row
  # (if any), the same way a national-id-driven autofill would — the two
  # lists are cross-referenced by FIDE id.
  defp merge_kbsb_by_fide_id(form_values, fide_id) do
    case Kbsb.find_by_fide_id(fide_id) do
      nil ->
        form_values

      kp ->
        Map.merge(form_values, %{
          "national_id" => kp.national_id,
          "national_rating" => kp.national_rating,
          "club" => kp.club_name
        })
    end
  end

  defp put_if_blank(map, _key, nil), do: map

  defp put_if_blank(map, key, value) do
    case Map.get(map, key) do
      v when v in [nil, ""] -> Map.put(map, key, value)
      _ -> map
    end
  end

  defp players_by_id(players), do: Map.new(players, &{&1.player.id, &1})

  defp error_text(changeset) do
    Enum.map_join(changeset.errors, ", ", fn {field, {msg, _}} -> "#{field} #{msg}" end)
  end

  defp all_columns, do: @all_columns

  defp cell(entry, "status"), do: entry.player.status

  defp cell(entry, key) when key in ~w(title sex birth_year federation national_id fide_id
                                        fide_rating national_rating club fixed_board) do
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

  defp cell(entry, "we"), do: format_score(entry.grid["we"])
  defp cell(entry, "wmwe"), do: format_signed(entry.grid["wmwe"])

  defp cell(entry, "diren") do
    case entry.grid["diren"] do
      value when value in [nil, 0, 0.0] -> "—"
      value -> format_num(value)
    end
  end

  defp cell(entry, key) when key in ~w(cl games pts buch bc1 sb prog) do
    format_num(entry.grid[key])
  end

  # SWAR admin columns, sourced straight from the player record (or the
  # entry's own :extra_points/:total, for the two computed ones).
  defp cell(entry, "aff"), do: if(entry.player.affiliated, do: "", else: "N")

  defp cell(entry, "pr") do
    cond do
      entry.player.absent -> "A"
      entry.player.forfeit -> "F"
      true -> ""
    end
  end

  defp cell(entry, "paid") do
    case entry.player.paid do
      "paid" -> "P"
      "nopaid" -> "N"
      "gratis" -> "G"
      _ -> "—"
    end
  end

  defp cell(entry, "xtpts"), do: format_num(entry.extra_points)
  defp cell(entry, "ptot"), do: format_num(entry.total)

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

  # We always shows two fixed decimals (SWAR/FIDE convention), unlike the
  # other numeric columns which trim trailing zeros.
  defp format_score(nil), do: "—"
  defp format_score(n), do: :erlang.float_to_binary(n / 1, decimals: 2)

  # W-We is signed: an explicit "+" for zero/positive, the built-in "-" for
  # negative values.
  defp format_signed(nil), do: "—"

  defp format_signed(n) do
    sign = if n >= 0, do: "+", else: ""
    sign <> :erlang.float_to_binary(n / 1, decimals: 2)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      tournament={@tournament}
      active="players"
    >
      <div class="page-header" id="players-page-header" phx-hook="AddPlayerShortcut">
        <div>
          <h1>{@tournament.name}</h1>
          
          <p class="subtitle" style="margin: 0">
            {length(@players)} player{if length(@players) != 1, do: "s"} registered
          </p>
        </div>
        
        <div class="actions" style="margin: 0">
          <a class="pe-btn" href={~p"/t/#{@tournament.id}/print/players"} target="_blank">
            Print player list
          </a>
          
          <a class="pe-btn" href={~p"/t/#{@tournament.id}/print/cards"} target="_blank">
            Print player cards
          </a>
          
          <a class="pe-btn" href={~p"/t/#{@tournament.id}/print/placecards"} target="_blank">
            Print place cards
          </a>
          
          <button type="button" class="pe-btn" phx-click="open_rating_refresh">
            Refresh ratings
          </button>
          
          <button
            :if={!@adding}
            class="pe-btn primary"
            phx-click="add"
            disabled={!@setup_complete}
            title={
              if @setup_complete,
                do: "Add player (Ctrl+I)",
                else: "Finish the tournament setup in Settings before adding players"
            }
          >
            Add player <span style="opacity: 0.7; font-size: 11px; margin-left: 4px">Ctrl+I</span>
          </button>
        </div>
      </div>
      
      <div :if={!@setup_complete} class="card error-note" style="display: block; margin: 12px 0">
        Finish the tournament setup — fill in the name, start date and number of rounds in
        <.link navigate={~p"/t/#{@tournament.id}/settings"}>Settings</.link>
        before adding players.
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
            <span>FIDE ID</span> <input name="player[fide_id]" value={@form_values["fide_id"]} />
          </label>
          
          <label class="field">
            <span>FIDE rating</span>
            <input type="number" name="player[fide_rating]" value={@form_values["fide_rating"]} />
          </label>
          
          <label class="field">
            <span>National ID</span>
            <input
              name="player[national_id]"
              value={@form_values["national_id"]}
              phx-change="lookup_kbsb_add"
              phx-debounce="250"
              autocomplete="off"
            />
          </label>
          
          <label class="field">
            <span>National rating</span>
            <input
              type="number"
              name="player[national_rating]"
              value={@form_values["national_rating"]}
            />
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
            <span>Club</span> <input name="player[club]" value={@form_values["club"]} />
          </label>
           <input type="hidden" name="player[sex]" value={@form_values["sex"]} />
        </div>
        
        <p :if={@error} class="error-note">{@error}</p>
        
        <div class="actions">
          <button
            type="submit"
            class="pe-btn primary"
            disabled={!@setup_complete}
            title={
              if !@setup_complete,
                do: "Finish the tournament setup in Settings before adding players"
            }
          >
            Add player
          </button>
           <button type="button" class="pe-btn" phx-click="done">Done</button>
        </div>
      </form>
      
      <div :if={@players == []} class="card empty">
        <p><strong>No players registered yet.</strong></p>
        
        <p>Add players by searching the FIDE database, or enter them by hand.</p>
      </div>
      
      <div :if={@players != []} class="split" id="players-grid" phx-hook="ColumnPrefs">
        <div class="card table-card split-main">
          <p class="hint" style="padding: 12px 16px 0">
            Double-click a row to edit the player, right-click for the Players Card.
          </p>
          
          <table class="pe-table" id="players-table" phx-hook="PlayerGrid">
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
              <tr :for={{p, i} <- Enum.with_index(@players, 1)} data-player-id={p.player.id}>
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
            /> {label}
          </label>
        </aside>
      </div>
      
      <.player_edit_modal
        :if={@editing_player}
        form={@edit_form}
        error={@edit_error}
        tournament={@tournament}
        titles={@titles}
      />
      <.player_card_modal
        :if={@card_player_id}
        entry={Map.get(players_by_id(@players), @card_player_id)}
        by_id={players_by_id(@players)}
        tournament={@tournament}
      /> <.rating_refresh_modal :if={@rating_refresh} summary={@rating_refresh} />
    </Layouts.app>
    """
  end

  ## ---------- Bulk rating refresh modal ----------

  attr :summary, :map, required: true

  defp rating_refresh_modal(assigns) do
    ~H"""
    <div class="modal-overlay" phx-window-keydown="close_rating_refresh" phx-key="escape">
      <div class="modal-card" phx-click-away="close_rating_refresh" style="max-width: 700px">
        <h2>Refresh ratings</h2>
        
        <p class="hint">
          Compares every registered player against the locally-synced FIDE and KBSB
          rating lists (by FIDE id / National id). Nothing is written until you Apply.
        </p>
        
        <div :if={@summary.proposals == []} class="card empty">
          <p><strong>Everything up to date.</strong></p>
        </div>
        
        <div :if={@summary.proposals != []} class="card-table-wrap">
          <table class="pe-table">
            <thead>
              <tr>
                <th>Player</th>
                
                <th>Field</th>
                
                <th class="num">Old</th>
                
                <th class="num">New</th>
              </tr>
            </thead>
            
            <tbody>
              <tr :for={p <- @summary.proposals}>
                <td>{p.player.name}</td>
                
                <td>{field_label(p.field)}</td>
                
                <td class="num">{blank_dash(p.old)}</td>
                
                <td class="num"><strong>{p.new}</strong></td>
              </tr>
            </tbody>
          </table>
        </div>
        
        <p class="hint">
          {@summary.checked} player{if @summary.checked != 1, do: "s"} checked, {@summary.changed} change{if @summary.changed !=
                                                                                                               1,
                                                                                                             do:
                                                                                                               "s"}, {@summary.unmatched} without id match.
        </p>
        
        <div class="actions">
          <button
            :if={@summary.proposals != []}
            type="button"
            class="pe-btn primary"
            phx-click="apply_rating_refresh"
          >
            Apply
          </button>
           <button type="button" class="pe-btn" phx-click="close_rating_refresh">Cancel</button>
        </div>
      </div>
    </div>
    """
  end

  defp field_label(:fide_rating), do: "FIDE rating"
  defp field_label(:national_rating), do: "National rating"
  defp field_label(:title), do: "Title"

  ## ---------- Player registration dialog (double-click) ----------

  attr :form, :map, required: true
  attr :error, :string, default: nil
  attr :tournament, :map, required: true
  attr :titles, :list, required: true

  defp player_edit_modal(assigns) do
    ~H"""
    <div class="modal-overlay" phx-window-keydown="close_edit" phx-key="escape">
      <form class="modal-card" phx-submit="save_player" phx-click-away="close_edit">
        <h2>Player registration</h2>
        
        <div class="form-grid">
          <label class="field" style="grid-column: 1 / -1">
            <span>Name</span> <input name="player[name]" value={@form["name"]} />
          </label>
          
          <label class="field">
            <span>Id Number</span>
            <div style="display:flex; gap:8px">
              <input name="player[national_id]" value={@form["national_id"]} />
              <button
                type="button"
                class="pe-btn"
                phx-click="refresh_edit_fide"
                title="Look up by FIDE id / name"
              >
                Refresh
              </button>
              
              <button
                type="button"
                class="pe-btn"
                phx-click="refresh_edit_kbsb"
                title="Look up by National ID in the KBSB database"
              >
                KBSB
              </button>
            </div>
          </label>
          
          <label class="field">
            <span>Birth Year</span>
            <input type="number" name="player[birth_year]" value={@form["birth_year"]} />
          </label>
          
          <div class="field">
            <span>Sex</span>
            <div class="radio-row">
              <label><input type="radio" name="player[sex]" value="m" checked={@form["sex"] == "m"} />
              M</label>
              <label><input type="radio" name="player[sex]" value="w" checked={@form["sex"] == "w"} />
              F</label>
            </div>
          </div>
          
          <label class="field">
            <span>Club</span> <input name="player[club]" value={@form["club"]} />
          </label>
          
          <label class="field">
            <span>Club nr</span>
            <input type="number" name="player[club_number]" value={@form["club_number"]} />
          </label>
          
          <label class="field">
            <span>Country</span>
            <input name="player[federation]" value={@form["federation"]} placeholder="BEL" />
          </label>
          
          <label class="field">
            <span>N-Elo</span>
            <input type="number" name="player[national_rating]" value={@form["national_rating"]} />
          </label>
          
          <label class="field">
            <span>Title</span>
            <select name="player[title]">
              <option value="">—</option>
              
              <option :for={t <- @titles} value={t} selected={@form["title"] == t}>{t}</option>
            </select>
          </label>
          
          <label class="field">
            <span>FIDE Id</span> <input name="player[fide_id]" value={@form["fide_id"]} />
          </label>
          
          <label class="field">
            <span>Elo FIDE</span>
            <input type="number" name="player[fide_rating]" value={@form["fide_rating"]} />
          </label>
          
          <label class="field">
            <span>Category</span>
            <select :if={@tournament.categories != []} name="player[category]">
              <option value="" selected={@form["category"] in [nil, ""]}>---</option>
              
              <option :for={c <- @tournament.categories} value={c} selected={@form["category"] == c}>
                {c}
              </option>
              
              <option
                :if={
                  @form["category"] not in [nil, ""] and
                    @form["category"] not in @tournament.categories
                }
                value={@form["category"]}
                selected
              >
                {@form["category"]} (not in list)
              </option>
            </select>
            
            <input
              :if={@tournament.categories == []}
              name="player[category]"
              value={@form["category"]}
            />
          </label>
          
          <div class="field" style="grid-column: 1 / -1">
            <span>Registration</span>
            <div class="radio-row">
              <label><input
                type="radio"
                name="player[paid]"
                value="nopaid"
                checked={@form["paid"] == "nopaid"}
              /> No Paid</label>
              <label><input
                type="radio"
                name="player[paid]"
                value="paid"
                checked={@form["paid"] == "paid"}
              /> Paid</label>
              <label><input
                type="radio"
                name="player[paid]"
                value="gratis"
                checked={@form["paid"] == "gratis"}
              /> Gratis</label>
            </div>
          </div>
          
          <div class="checkbox-row" style="grid-column: 1 / -1">
            <label>
              <input type="hidden" name="player[absent]" value="false" />
              <input
                type="checkbox"
                name="player[absent]"
                value="true"
                checked={@form["absent"] in [true, "true"]}
              /> Absent
            </label>
            
            <label>
              <input type="hidden" name="player[forfeit]" value="false" />
              <input
                type="checkbox"
                name="player[forfeit]"
                value="true"
                checked={@form["forfeit"] in [true, "true"]}
              /> Forfeit
            </label>
          </div>
          
          <label class="field">
            <span>Fixed table</span>
            <input
              type="number"
              min="1"
              name="player[fixed_board]"
              value={@form["fixed_board"]}
              placeholder="none"
              title="Displays/prints this player's games at this table number, regardless of normal board order"
            />
          </label>
          
          <label class="field" style="grid-column: 1 / -1">
            <span>Absent at the rounds (e.g. 3,5 or 2-4)</span>
            <input name="player[absent_rounds]" value={@form["absent_rounds"]} />
          </label>
          
          <label class="field">
            <span>Extra Points</span>
            <input type="number" step="0.5" name="player[extra_points]" value={@form["extra_points"]} />
          </label>
        </div>
        
        <p :if={@error} class="error-note">{@error}</p>
        
        <div class="actions">
          <button type="submit" class="pe-btn primary">Save</button>
          <button type="button" class="pe-btn" phx-click="close_edit">Cancel</button>
        </div>
      </form>
    </div>
    """
  end

  ## ---------- Players Card (right-click) ----------

  attr :entry, :map, default: nil
  attr :by_id, :map, required: true
  attr :tournament, :map, required: true

  defp player_card_modal(%{entry: nil} = assigns), do: ~H""

  defp player_card_modal(assigns) do
    rows = PlayerCard.rows(assigns.entry, assigns.by_id, assigns.tournament)
    assigns = assign(assigns, rows: rows, totals: PlayerCard.totals(rows, assigns.entry))

    ~H"""
    <div class="modal-overlay" phx-window-keydown="close_card" phx-key="escape">
      <div class="modal-card" phx-click-away="close_card" style="max-width: 900px">
        <h2>Players Card</h2>
        
        <p class="card-header-line">{PlayerCard.header(@entry)}</p>
        
        <div class="card-table-wrap">
          <table class="pe-table">
            <thead>
              <tr>
                <th class="num">N°</th>
                
                <th class="num">Rnk</th>
                
                <th>Nat</th>
                
                <th>Tit</th>
                
                <th>Opponent</th>
                
                <th class="num">N-Elo</th>
                
                <th class="num">Pts</th>
                
                <th class="num">Res</th>
                
                <th class="num">Cl</th>
                
                <th class="num">Flt</th>
              </tr>
            </thead>
            
            <tbody>
              <tr :for={row <- @rows}>
                <td class="num">{row.round}</td>
                
                <td class="num">{row.opponent_pairing_number || "-"}</td>
                
                <td>{row.opponent_federation || "-"}</td>
                
                <td>{blank_dash(row.opponent_title)}</td>
                
                <td>{row.opponent_name || "-"}</td>
                
                <td class="num">{row.opponent_elo || "-"}</td>
                
                <td class="num">{format_num(row.opponent_total)}</td>
                
                <td class="num">{row.result}</td>
                
                <td class="num">{row.colour}</td>
                
                <td class="num">{row.float}</td>
              </tr>
              
              <tr class="card-total-row">
                <td colspan="6">Total</td>
                
                <td class="num">{format_num(@totals.opponent_total)}</td>
                
                <td class="num">{format_num(@totals.own_total)}</td>
                
                <td colspan="2"></td>
              </tr>
            </tbody>
          </table>
        </div>
        
        <div class="actions">
          <button type="button" class="pe-btn" phx-click="card_prev">Previous</button>
          <button type="button" class="pe-btn" phx-click="card_next">Following</button>
          <button type="button" class="pe-btn primary" phx-click="close_card">Exit</button>
        </div>
      </div>
    </div>
    """
  end

  defp blank_dash(nil), do: "-"
  defp blank_dash(""), do: "-"
  defp blank_dash(value), do: value
end
