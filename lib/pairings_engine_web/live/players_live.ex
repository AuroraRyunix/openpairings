defmodule PairingsEngineWeb.PlayersLive do
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport, only: [setup_field_path: 2]

  alias PairingsEngine.{
    Audit,
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

  # Player grid columns, in SWAR-parity display order. Which ones show is up
  # to the user (Display panel); toggling is by `key`, order is fixed by this
  # list (except the tiebreak columns — see `tiebreak_columns/1` below, which
  # splices `@tiebreak_columns` into this sequence according to the
  # tournament's own configured tiebreak order). Fourth element of every
  # 4-tuple is the header tooltip shown via `title=`.
  @columns_before_tiebreaks [
    {"cl", "Cl", true, "Current standings rank (classement)"},
    {"aff", "Aff.", false, "Federation affiliation (blank = affiliated, N = not affiliated)"},
    # SWAR's presence notation — see `cell/2`'s "pr" clause. Not a `num`
    # column: the value is a marker plus a comma-separated list, so
    # right-aligning it as a number would be wrong.
    {"pr", "Pr.", false,
     "Presence. F = forfeit, A = absent all event, A(1,2,3) = sitting out those " <>
       "rounds AND absent for the round being paired now, a(1,2,3) = sat out those " <>
       "rounds but available again"},
    {"paid", "Paid", false, "Registration fee status (P = paid, N = not paid, G = gratis)"},
    {"nr", "Nr", true, "Pairing number (starting number), frozen once the first round is paired"},
    {"rnk", "Rnk", true,
     "Live rating-based seed: the pairing-number position this player would get if starting numbers were assigned fresh right now (highest rating first, ties by name) — recomputed on every view, so it can drift from the frozen Nr after a rating correction or a late addition"},
    {"cat", "Cat", false,
     "Prize category (SWAR CATEGORIES) — only the categories defined for this tournament on " <>
       "the Categories settings page, assigned per player either by hand or by the " <>
       "\"Assign categories\" button's threshold rules"},
    {"birth_year", "Birth", true, "Year of birth"},
    {"sex", "Sex", false, "Player's sex (M/F)"},
    {"federation", "Country", false, "Federation / country code (e.g. BEL)"},
    {"national_id", "Id Nat", true, "National federation ID number"},
    {"fide_id", "Id FIDE", true, "FIDE ID number"},
    {"national_rating", "Elo Nat", true, "National federation rating"},
    {"fide_rating", "Elo FIDE", true, "FIDE (international) rating"},
    {"elo_used", "Elo used", true,
     "The rating actually used for pairing/performance/tiebreak calculations — FIDE rating if the player has one, otherwise the national rating"},
    {"title", "Title", false, "Chess title (GM, IM, FM, WGM, etc.)"},
    {"club", "Club", false, "Chess club"},
    {"games", "Ga", true, "Games played"},
    {"pts", "Pts", true, "Points (game score, excluding extra points)"},
    {"status", "Status", false, "Player status (active, withdrawn, etc.)"},
    {"fixed_board", "Table", true,
     "Fixed table number — this player's games always print/display at this board, regardless of normal board order"},
    {"perf", "Perf", true,
     "Performance rating: average opponent rating adjusted for wins/losses"},
    {"we", "We", true, "Expected score from rating (FIDE table)"},
    {"wmwe", "W-We", true, "Actual score minus expected score (W - We)"}
  ]

  # Tiebreak columns — order among themselves is tournament-dependent (see
  # `tiebreak_columns/1`), this is just the fallback order for any tiebreak
  # NOT in the tournament's configured `tiebreaks` list.
  @tiebreak_columns [
    {"buch", "Buch", true, "Buchholz tiebreak (sum of opponents' scores)"},
    {"bc1", "B C1", true,
     "Buchholz cut-1 tiebreak (Buchholz with the lowest-scoring opponent dropped)"},
    {"sb", "S.B.", true, "Sonneborn-Berger tiebreak"},
    {"prog", "Prog.", true, "Progressive/cumulative score (running total after each round)"},
    {"diren", "DirEn", true,
     "Direct encounter tiebreak: points scored against opponents tied on the same score (only decisive once the whole tied group has played each other)"}
  ]

  # Maps `tournament.tiebreaks` codes (as used by Standings) to the grid keys
  # above — only the tiebreaks the grid actually displays as columns.
  @tiebreak_code_to_key %{
    "BH" => "buch",
    "BHC1" => "bc1",
    "SB" => "sb",
    "PS" => "prog",
    "DE" => "diren"
  }

  @columns_after_tiebreaks [
    {"xtpts", "XtPts", true, "Extra points (administrative bonus points added by the organizer)"},
    {"ptot", "P.Tot.", true, "Total points including extra points"}
  ]

  @default_visible ~w(title birth_year federation fide_id fide_rating national_rating club) ++
                     ~w(cl games pts xtpts ptot pr)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    # Clears the "another arbiter" notice the moment the user interacts with
    # the page again — same reasoning as PairingsLive's identical hook: a
    # self-clearing timer alone would leave it sitting through an
    # in-progress click, and there's no harm clearing it eagerly since every
    # mutating event already refreshes the player data itself.
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
       sort_col: nil,
       sort_dir: nil,
       remote_notice: false,
       setup_complete: Tournament.setup_complete?(tournament),
       missing_setup: Tournament.missing_setup_fields(tournament)
     )
     |> assign_players()}
  end

  # Another user (or another tab) changed this tournament's data — reload
  # the players list and the tournament itself, but leave any open
  # modal/form (add-player form, edit-player modal, players card) alone so
  # we don't clobber whatever the user is mid-typing there.
  #
  # Same "compare before vs after refresh" trick PairingsLive's identical
  # notice uses, for the identical reason: this LiveView is subscribed to
  # its own tournament's topic, so a mutation it caused ITSELF echoes right
  # back here too, after `refresh/1` already ran synchronously — comparing
  # the freshly reloaded grid against what's already on screen tells "my
  # own echo" apart from "someone else actually changed something" without
  # separate bookkeeping.
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
        old_players = socket.assigns.players

        socket =
          socket
          |> assign(
            tournament: tournament,
            setup_complete: Tournament.setup_complete?(tournament),
            missing_setup: Tournament.missing_setup_fields(tournament)
          )
          |> assign_players()

        socket =
          if socket.assigns.players != old_players do
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

  defp assign_players(socket) do
    tournament = socket.assigns.tournament

    entries =
      tournament
      |> Standings.grid_standings()
      |> build_grid(tournament)
      |> sort_entries(socket.assigns[:sort_col], socket.assigns[:sort_dir])

    assign(socket, :players, entries)
  end

  # No column chosen (or the current one was toggled back off) — default
  # order: the real tournament ranking. `entry.rank` (set by
  # `Standings.grid_standings/1`, via `build_standings/3`) already sorts by
  # points/total descending, then the tournament's own configured
  # `tiebreaks` in order, and — because `Tournaments.list_players/1` (the
  # source list `build_standings/3` folds over) itself orders by rating
  # descending then name ascending, and `Enum.sort_by/2` is stable — any
  # remaining tie naturally falls back to rating descending, then name
  # ascending. That's exactly "points, then configured tiebreaks, then
  # rating" with no need to re-derive it here.
  defp sort_entries(entries, nil, _dir) do
    Enum.sort_by(entries, & &1.rank)
  end

  defp sort_entries(entries, col, dir) do
    entries
    |> Enum.map(&{&1, sort_value(&1, col)})
    |> Enum.sort(fn {_e1, v1}, {_e2, v2} -> sort_lte?(v1, v2, dir) end)
    |> Enum.map(&elem(&1, 0))
  end

  # `sort_value/2` returns `{blank?, comparable_value}` — blanks (nil/"—"
  # equivalents, matching what `cell/2` itself treats as blank for that
  # column) always sort last, in either direction. `comparable_value` is the
  # same underlying value the cell displays (never its rendered string),
  # normalized to a case-insensitive string for text columns so comparisons
  # never crash on mixed types.
  defp sort_lte?({1, _}, {1, _}, _dir), do: true
  defp sort_lte?({1, _}, {0, _}, _dir), do: false
  defp sort_lte?({0, _}, {1, _}, _dir), do: true
  defp sort_lte?({0, v1}, {0, v2}, :asc), do: v1 <= v2
  defp sort_lte?({0, v1}, {0, v2}, :desc), do: v1 >= v2

  defp sort_value(entry, "name"), do: text_sort_value(entry.player.name)

  defp sort_value(entry, key) when key in ~w(title sex federation club status) do
    entry.player |> Map.get(String.to_existing_atom(key)) |> text_sort_value()
  end

  defp sort_value(entry, "national_id"), do: text_sort_value(entry.player.national_id)

  defp sort_value(entry, key)
       when key in ~w(fide_id fide_rating national_rating birth_year fixed_board) do
    case Map.get(entry.player, String.to_existing_atom(key)) do
      value when value in [nil, "", 0] -> {1, nil}
      value -> {0, value}
    end
  end

  defp sort_value(entry, "cl"), do: numeric_sort_value(entry.rank)
  defp sort_value(entry, "nr"), do: numeric_sort_value(entry.grid["nr"])
  defp sort_value(entry, "rnk"), do: numeric_sort_value(entry.grid["rnk"])

  defp sort_value(entry, "elo_used") do
    case entry.grid["elo_used"] do
      value when value in [nil, 0] -> {1, nil}
      value -> {0, value}
    end
  end

  defp sort_value(entry, "cat"), do: text_sort_value(entry.grid["cat"])
  defp sort_value(entry, "games"), do: numeric_sort_value(entry.grid["games"])
  defp sort_value(entry, "pts"), do: numeric_sort_value(entry.grid["pts"])
  defp sort_value(entry, "perf"), do: numeric_sort_value(entry.grid["perf"])
  defp sort_value(entry, "we"), do: numeric_sort_value(entry.grid["we"])
  defp sort_value(entry, "wmwe"), do: numeric_sort_value(entry.grid["wmwe"])
  defp sort_value(entry, "buch"), do: numeric_sort_value(entry.grid["buch"])
  defp sort_value(entry, "bc1"), do: numeric_sort_value(entry.grid["bc1"])
  defp sort_value(entry, "sb"), do: numeric_sort_value(entry.grid["sb"])
  defp sort_value(entry, "prog"), do: numeric_sort_value(entry.grid["prog"])

  defp sort_value(entry, "diren") do
    case entry.grid["diren"] do
      value when value in [nil, 0, 0.0] -> {1, nil}
      value -> {0, value}
    end
  end

  defp sort_value(entry, "aff") do
    case entry.player.affiliated do
      nil -> {1, nil}
      value -> {0, value}
    end
  end

  defp sort_value(entry, "pr") do
    cond do
      entry.player.absent -> {0, "A"}
      entry.player.forfeit -> {0, "F"}
      true -> {1, nil}
    end
  end

  defp sort_value(entry, "paid") do
    case entry.player.paid do
      value when value in ["paid", "nopaid", "gratis"] -> {0, value}
      _ -> {1, nil}
    end
  end

  defp sort_value(entry, "xtpts"), do: numeric_sort_value(entry.extra_points)
  defp sort_value(entry, "ptot"), do: numeric_sort_value(entry.total)

  defp text_sort_value(value) when value in [nil, ""], do: {1, nil}
  defp text_sort_value(value), do: {0, value |> to_string() |> String.downcase()}

  defp numeric_sort_value(nil), do: {1, nil}
  defp numeric_sort_value(value), do: {0, value}

  # Attaches a `:grid` map of the SWAR-style computed columns to each
  # standings entry, keyed by the column key used in the column lists above
  # (`@columns_before_tiebreaks` / `@tiebreak_columns` / `@columns_after_tiebreaks`).
  defp build_grid(entries, tournament) do
    players_by_id = Map.new(entries, &{&1.player.id, &1.player})

    # The round about to be paired — what decides whether a "Pr." cell
    # shows a capital or a lowercase marker.
    current_round = Standings.rounds_paired(tournament.id) + 1

    # "Rnk" — a live (unfrozen) re-derivation of the same rule
    # `Pairing.ensure_pairing_numbers/2` uses to freeze `Nr`: highest rating
    # first, ties broken by name. Recomputed over the currently registered
    # player list on every render, so it can drift from the frozen `nr` grid
    # value above once ratings are corrected or players are added out of
    # order after numbers were frozen.
    live_seed_rank_by_id =
      players_by_id
      |> Map.values()
      |> Enum.sort_by(&{-Player.rating(&1), &1.name})
      |> Enum.with_index(1)
      |> Map.new(fn {player, idx} -> {player.id, idx} end)

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
        "rnk" => Map.get(live_seed_rank_by_id, entry.player.id),
        "elo_used" => Player.rating(entry.player),
        # The tournament's OWN category (see Tournament.categories), never a
        # derived age bracket — the arbiter defines the category set, so
        # nothing here may invent one they didn't create.
        "cat" => entry.player.category || "",
        "games" => length(played_games),
        "pts" => entry.points,
        "perf" => PlayerStats.performance(opponent_ratings, wins, losses),
        "we" => we,
        "wmwe" => PlayerStats.w_minus_we(w_counted, we),
        "buch" => Map.get(entry.tiebreaks, "BH"),
        "bc1" => Map.get(entry.tiebreaks, "BHC1"),
        "sb" => Map.get(entry.tiebreaks, "SB"),
        "prog" => Map.get(entry.tiebreaks, "PS"),
        "diren" => Map.get(entry.tiebreaks, "DE", 0.0),
        "current_round" => current_round
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
         "Finish the tournament setup before adding players — missing: " <>
           missing_setup_summary(socket.assigns.missing_setup)
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

  # Clicking a header sorts by that column, ascending first; clicking the
  # same header again flips direction; clicking a different header resets to
  # ascending on the new column.
  def handle_event("sort", %{"key" => key}, socket) do
    dir =
      case {socket.assigns.sort_col, socket.assigns.sort_dir} do
        {^key, :asc} -> :desc
        {^key, :desc} -> :asc
        _ -> :asc
      end

    {:noreply, socket |> assign(sort_col: key, sort_dir: dir) |> assign_players()}
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
          "fide_rating" => Fide.rating_for_tempo(fp, socket.assigns.tournament.standard),
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
         "Finish the tournament setup before adding players — missing: " <>
           missing_setup_summary(socket.assigns.missing_setup)
       )}
    else
      do_save(socket, params)
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Tournaments.get_player(socket.assigns.tournament.id, id) do
      nil ->
        {:noreply, socket}

      player ->
        case Tournaments.delete_player(player) do
          {:ok, _} ->
            Audit.log(
              socket.assigns.tournament.id,
              socket.assigns.current_scope,
              "player.deleted",
              %{player_id: player.id, player_name: player.name}
            )

          _ ->
            :ok
        end

        {:noreply, assign_players(socket)}
    end
  end

  ## ---------- Pr. cell right-click menu (whole-tournament presence) ----------
  #
  # "All Absent" / "All Present" from the Pr. cell's context menu touch only
  # the whole-tournament `absent` flag — SWAR's plain "A" with no rounds
  # listed, per `cell(entry, "pr")` above. They deliberately leave
  # `absent_rounds` untouched: a player who is "All Present" here can still
  # have specific rounds marked, and clearing/setting this flag must not
  # silently erase those. Per-round marks stay a job for the edit dialog.
  def handle_event("set_absent_flag", %{"id" => id, "value" => value}, socket) do
    absent? = value in ["true", true]

    case Tournaments.get_player(socket.assigns.tournament.id, id) do
      nil ->
        {:noreply, socket}

      player ->
        case Tournaments.update_player(player, %{"absent" => absent?}) do
          {:ok, updated} ->
            if updated.absent != player.absent do
              Audit.log(
                socket.assigns.tournament.id,
                socket.assigns.current_scope,
                "player.updated",
                %{
                  player_id: player.id,
                  player_name: player.name,
                  changed_fields: %{"absent" => [player.absent, updated.absent]}
                }
              )
            end

            {:noreply, assign_players(socket)}

          {:error, _changeset} ->
            {:noreply, socket}
        end
    end
  end

  # Right-clicking the Pr. COLUMN HEADER instead of one player's cell —
  # same whole-tournament flag, applied to every player in the tournament
  # at once. `set_all_players_absent/2` touches only `absent`;
  # `absent_rounds` is untouched for everyone, same guarantee as the
  # single-player version above.
  def handle_event("set_all_absent_flag", %{"value" => value}, socket) do
    absent? = value in ["true", true]
    tournament_id = socket.assigns.tournament.id

    case Tournaments.set_all_players_absent(tournament_id, absent?) do
      {:ok, players} ->
        Audit.log(
          tournament_id,
          socket.assigns.current_scope,
          "player.bulk_absent_set",
          %{absent: absent?, player_count: length(players)}
        )

        {:noreply, assign_players(socket)}

      {:error, _changeset} ->
        {:noreply, socket}
    end
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
      {:ok, players} ->
        Audit.log(
          socket.assigns.tournament.id,
          socket.assigns.current_scope,
          "player.ratings_refreshed",
          %{players_updated: length(players)}
        )

        {:noreply, socket |> assign(rating_refresh: nil) |> assign_players()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not apply the rating refresh")}
    end
  end

  ## ---------- Player registration dialog (double-click a row) ----------

  def handle_event("edit_player", %{"id" => id}, socket) do
    case Tournaments.get_player(socket.assigns.tournament.id, id) do
      nil ->
        {:noreply, socket}

      player ->
        {:noreply,
         assign(socket,
           editing_player: player,
           edit_form: player_to_form(player),
           edit_error: nil
         )}
    end
  end

  def handle_event("close_edit", _params, socket) do
    {:noreply, assign(socket, editing_player: nil, edit_form: %{}, edit_error: nil)}
  end

  def handle_event("dismiss_remote_notice", _params, socket) do
    {:noreply, assign(socket, remote_notice: false)}
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
            "fide_rating" => Fide.rating_for_tempo(fp, socket.assigns.tournament.standard),
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
    before = socket.assigns.editing_player

    case Tournaments.update_player(before, params) do
      {:ok, player} ->
        changed = player_diff(before, player)

        if changed != %{} do
          Audit.log(
            socket.assigns.tournament.id,
            socket.assigns.current_scope,
            "player.updated",
            %{player_id: player.id, player_name: player.name, changed_fields: changed}
          )
        end

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

  # Tracked player fields whose before/after change is worth recording in the
  # audit trail — returns a `%{"field" => [before, after]}` map of only the
  # fields that actually changed (empty map when nothing tracked changed).
  @audited_player_fields ~w(name title sex fide_id fide_rating national_rating
    federation club club_number birth_year category status absent forfeit
    absent_rounds fixed_board start_round extra_points manual_rank)a

  defp player_diff(before, after_player) do
    for field <- @audited_player_fields,
        Map.get(before, field) != Map.get(after_player, field),
        into: %{} do
      {to_string(field), [Map.get(before, field), Map.get(after_player, field)]}
    end
  end

  defp do_save(socket, params) do
    case Tournaments.create_player(socket.assigns.tournament.id, params) do
      {:ok, player} ->
        Audit.log(socket.assigns.tournament.id, socket.assigns.current_scope, "player.created", %{
          player_id: player.id,
          player_name: player.name,
          rating: Player.rating(player)
        })

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

  # Plain-text summary of `Tournament.missing_setup_fields/1`'s messages, for
  # the flash shown when "Add player" is blocked — the on-page banner (see
  # render/1) additionally links each item to the Settings (sub-)page it
  # lives on.
  defp missing_setup_summary(missing) do
    Enum.map_join(missing, "; ", fn {_field, message} -> message end)
  end

  # Full column list for `tournament`: the fixed sequence with the tiebreak
  # columns spliced in at the tournament's own configured order — any
  # tiebreak the tournament doesn't have configured (or a tournament with no
  # tiebreaks configured, i.e. `tiebreaks == []`) falls back to appearing
  # after the configured ones, in `@tiebreak_columns`'s fixed order.
  defp all_columns(tournament) do
    @columns_before_tiebreaks ++ tiebreak_columns(tournament) ++ @columns_after_tiebreaks
  end

  defp tiebreak_columns(tournament) do
    configured_keys =
      tournament.tiebreaks
      |> Enum.map(&Map.get(@tiebreak_code_to_key, &1))
      |> Enum.reject(&is_nil/1)

    by_key = Map.new(@tiebreak_columns, &{elem(&1, 0), &1})

    ordered = configured_keys |> Enum.map(&Map.get(by_key, &1)) |> Enum.reject(&is_nil/1)
    leftover = Enum.reject(@tiebreak_columns, fn {key, _, _, _} -> key in configured_keys end)

    ordered ++ leftover
  end

  # Small ▲/▼ suffix shown in a header when it's the active sort column.
  defp sort_indicator(col, :asc, col), do: " ▲"
  defp sort_indicator(col, :desc, col), do: " ▼"
  defp sort_indicator(_col, _dir, _key), do: ""

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
  defp cell(entry, "rnk"), do: format_num(entry.grid["rnk"])

  defp cell(entry, "elo_used") do
    case entry.grid["elo_used"] do
      value when value in [nil, 0] -> "—"
      value -> value
    end
  end

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

  # SWAR's own presence notation, which packs three facts into one cell:
  #
  #     F           forfeited / withdrawn
  #     A           absent for the WHOLE event (the `absent` boolean)
  #     A(1,2,3)    sitting out those rounds, and one of them is the round
  #                 now being paired — so absent RIGHT NOW
  #     a(1,2,3)    sat out those rounds, but the current round is not one
  #                 of them — so back in play
  #
  # The case is the whole point: capital means "absent for the round you
  # are about to pair", lowercase means "has absences on record but is
  # available now". An arbiter scanning the grid before pairing needs that
  # distinction more than either fact on its own, which is why this
  # replaced the separate rounds column added just before it — two columns
  # off the same field meant reading both to answer one question.
  defp cell(entry, "pr") do
    player = entry.player
    rounds = to_string(player.absent_rounds)

    cond do
      player.forfeit ->
        "F"

      player.absent ->
        "A"

      rounds == "" ->
        ""

      true ->
        # Already canonical ascending-unique from
        # `Player.normalize_absent_rounds/1`, so this is a plain membership
        # test rather than any re-parsing.
        absent_now? = to_string(entry.grid["current_round"]) in String.split(rounds, ",")
        if(absent_now?, do: "A", else: "a") <> "(" <> rounds <> ")"
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
  # `PrintController.player_list/2`'s optional columns — Title, FIDE,
  # Elo Nat, Country, Club — narrowed to whichever of those this LiveView's
  # own Display panel currently has checked, so "Print player list" shows
  # what the arbiter is looking at on screen rather than a fixed set.
  # Keep in sync with `PairingsEngine.PrintController.@player_list_optional_columns`.
  # Every grid column the printed player list can actually render — see
  # `PairingsEngineWeb.PrintController`'s `@player_list_columns`, which
  # uses these same keys. The score-derived columns (Cl/Pts/Ga/Perf/We/
  # W-We/tiebreaks) are deliberately absent: those are what the Print
  # standings button is for.
  @printable_player_list_columns ~w(
    pr aff paid nr cat title birth_year sex federation
    national_id fide_id national_rating fide_rating elo_used
    club status fixed_board
  )

  defp printable_player_list_columns(visible) do
    @printable_player_list_columns |> Enum.filter(&(&1 in visible)) |> Enum.join(",")
  end

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
      <div
        :if={@remote_notice}
        class="card"
        style="display: flex; align-items: center; justify-content: space-between; gap: 8px; margin-bottom: 12px; padding: 8px 12px; border-left: 3px solid var(--accent)"
      >
        <span>Player data was just updated by another arbiter - refreshed.</span>
        <button
          type="button"
          class="pe-btn"
          style="padding: 2px 8px"
          phx-click="dismiss_remote_notice"
        >
          Dismiss
        </button>
      </div>

      <div class="page-header" id="players-page-header" phx-hook="AddPlayerShortcut">
        <div>
          <h1>{@tournament.name}</h1>

          <p class="subtitle" style="margin: 0">
            {length(@players)} player{if length(@players) != 1, do: "s"} registered
          </p>
        </div>

        <div class="actions" style="margin: 0">
          <a
            class="pe-btn"
            href={
              ~p"/t/#{@tournament.id}/print/players?#{[cols: printable_player_list_columns(@visible)]}"
            }
            target="_blank"
          >
            Print player list
          </a>

          <a class="pe-btn" href={~p"/t/#{@tournament.id}/print/cards"} target="_blank">
            Print player cards
          </a>

          <a class="pe-btn" href={~p"/t/#{@tournament.id}/print/placecards"} target="_blank">
            Print place cards
          </a>

          <button
            type="button"
            class="pe-btn"
            phx-click="open_rating_refresh"
            title="Compare every registered player against the locally-synced FIDE/KBSB databases and preview rating/title updates before applying them"
          >
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
                else:
                  "Finish the tournament setup first - missing: " <>
                    missing_setup_summary(@missing_setup)
            }
          >
            Add player <span style="opacity: 0.7; font-size: 11px; margin-left: 4px">Ctrl+I</span>
          </button>
        </div>
      </div>

      <div :if={!@setup_complete} class="card error-note" style="display: block; margin: 12px 0">
        Finish the tournament setup before adding players - still missing:
        <ul style="margin: 6px 0 0; padding-left: 20px">
          <li :for={{field, message} <- @missing_setup}>
            <.link navigate={setup_field_path(@tournament, field)}>{message}</.link>
          </li>
        </ul>
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
                {fp.federation} · {fp.standard_rating || "unrated"} · {fp.birth_year || "-"}
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
              <option value="">-</option>

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
                do:
                  "Finish the tournament setup first - missing: " <>
                    missing_setup_summary(@missing_setup)
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
            Double-click a row to edit the player, right-click for the Players Card
            — right-click a player's Pr. cell for that player's All Absent / All Present,
            or right-click the <strong>Pr. column header</strong> to set it for everyone at once.
          </p>

          <table class="pe-table" id="players-table" phx-hook="PlayerGrid">
            <thead>
              <tr>
                <th
                  class={["num", "sortable"]}
                  phx-click="sort"
                  phx-value-key="cl"
                  title="Live tournament rank - click to sort by current standings rank (same as Cl)"
                >
                  N1{sort_indicator(@sort_col, @sort_dir, "cl")}
                </th>

                <th class="sortable" phx-click="sort" phx-value-key="name" title="Player's full name">
                  Name{sort_indicator(@sort_col, @sort_dir, "name")}
                </th>

                <th
                  :for={{key, label, num, desc} <- all_columns(@tournament)}
                  :if={key in @visible}
                  class={[num && "num", "sortable"]}
                  data-col={key}
                  phx-click="sort"
                  phx-value-key={key}
                  title={
                    if key == "pr",
                      do: desc <> " — right-click for All Absent / All Present",
                      else: desc
                  }
                >
                  {label}{sort_indicator(@sort_col, @sort_dir, key)}
                </th>

                <th></th>
              </tr>
            </thead>

            <tbody>
              <tr :for={{p, i} <- Enum.with_index(@players, 1)} data-player-id={p.player.id}>
                <td class="num">{i}</td>

                <td><strong>{p.player.name}</strong></td>

                <td
                  :for={{key, _label, num, _desc} <- all_columns(@tournament)}
                  :if={key in @visible}
                  class={num && "num"}
                  data-col={key}
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

          <label :for={{key, label, _num, _desc} <- all_columns(@tournament)} class="check">
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

  # `Player.rating/1`'s own FIDE-first-then-national logic, worked from the
  # edit form's raw string values instead of a saved `%Player{}` — the form
  # can hold an unsaved edit the stored struct doesn't have yet, and this is
  # what "Elo used" in the registration dialog needs to reflect live as the
  # arbiter types, not just after a save round-trip.
  defp elo_used_from_form(form) do
    fide = parse_rating(form["fide_rating"])
    national = parse_rating(form["national_rating"])
    if fide > 0, do: fide, else: if(national > 0, do: national, else: nil)
  end

  defp parse_rating(nil), do: 0
  defp parse_rating(""), do: 0

  defp parse_rating(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp parse_rating(value) when is_integer(value), do: value
  defp parse_rating(_), do: 0

  ## ---------- Player registration dialog (double-click) ----------

  attr :form, :map, required: true
  attr :error, :string, default: nil
  attr :tournament, :map, required: true
  attr :titles, :list, required: true

  defp player_edit_modal(assigns) do
    assigns =
      assigns
      |> Phoenix.Component.assign(:fide_player, Fide.get_player(assigns.form["fide_id"]))
      |> Phoenix.Component.assign(:elo_used, elo_used_from_form(assigns.form))

    ~H"""
    <div class="modal-overlay" phx-window-keydown="close_edit" phx-key="escape">
      <form class="modal-card" phx-submit="save_player" phx-click-away="close_edit">
        <h2>Player registration</h2>

        <div class="modal-lookup-bar">
          <span class="hint" style="margin:0">Auto-fill from the local rating databases:</span>
          <button
            type="button"
            class="pe-btn"
            phx-click="refresh_edit_fide"
            title="Look up this player in the local FIDE rating database (by FIDE ID if set, otherwise by name) and fill in their title, FIDE rating, federation and birth year"
          >
            FIDE lookup
          </button>

          <button
            type="button"
            class="pe-btn"
            phx-click="refresh_edit_kbsb"
            title="Look up this player in the local KBSB (Belgian) rating database by National ID and fill in their national rating, club, federation, birth year and FIDE ID"
          >
            KBSB lookup
          </button>
        </div>

        <div class="form-grid">
          <label class="field" style="grid-column: 1 / -1">
            <span>Name</span> <input name="player[name]" value={@form["name"]} />
          </label>
          <%!-- Identity --%>
          <label class="field">
            <span>National ID</span> <input name="player[national_id]" value={@form["national_id"]} />
          </label>

          <label class="field">
            <span>FIDE ID</span> <input name="player[fide_id]" value={@form["fide_id"]} />
          </label>

          <label class="field">
            <span>Country</span>
            <input name="player[federation]" value={@form["federation"]} placeholder="BEL" />
          </label>
          <%!-- Ratings & title --%>
          <label class="field">
            <span>National Elo</span>
            <input type="number" name="player[national_rating]" value={@form["national_rating"]} />
          </label>

          <label class="field">
            <span>FIDE Elo</span>
            <input type="number" name="player[fide_rating]" value={@form["fide_rating"]} />
            <span :if={@fide_player} class="hint" style="display: block; margin-top: 2px">
              Standard {@fide_player.standard_rating || "—"} · Rapid {@fide_player.rapid_rating ||
                "—"} · Blitz {@fide_player.blitz_rating || "—"}
              <span :if={@tournament.standard in ["rapid", "blitz"]}>
                (this is a {String.capitalize(@tournament.standard)} tournament — refreshing fills
                in the {String.capitalize(@tournament.standard)} rating, or Standard if this player
                has none yet)
              </span>
            </span>
            <span class="hint" style="display: block">
              Elo used (pairing/standings): <strong>{@elo_used || "unrated"}</strong>
            </span>
          </label>

          <label class="field">
            <span>Title</span>
            <select name="player[title]">
              <option value="">-</option>

              <option :for={t <- @titles} value={t} selected={@form["title"] == t}>{t}</option>
            </select>
          </label>
          <%!-- Personal --%>
          <label class="field">
            <span>Birth year</span>
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
          <%!-- Club & board --%>
          <label class="field">
            <span>Club</span> <input name="player[club]" value={@form["club"]} />
          </label>

          <label class="field">
            <span>Club nr</span>
            <input type="number" name="player[club_number]" value={@form["club_number"]} />
          </label>

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
          <%!-- Scoring admin --%>
          <label class="field">
            <span>Extra points</span>
            <input type="number" step="0.5" name="player[extra_points]" value={@form["extra_points"]} />
          </label>

          <label class="field" style="grid-column: span 2">
            <span>Absent at the rounds (e.g. 3,5 or 2-4)</span>
            <input name="player[absent_rounds]" value={@form["absent_rounds"]} />
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
