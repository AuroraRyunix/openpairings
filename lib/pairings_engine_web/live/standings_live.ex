defmodule PairingsEngineWeb.StandingsLive do
  use PairingsEngineWeb, :live_view

  alias PairingsEngineWeb.PublicLink

  alias PairingsEngine.{Audit, Categories, Tournaments, Tiebreaks, Standings, Keizer, PlayerStats}
  alias PairingsEngine.Tournaments.{Player, Tournament}

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
       page_title: "#{tournament.name} · Standings",
       # `nil` until the ColumnPrefs hook reports back what's actually
       # stored in localStorage (see `show_col?/2`) - nil means "no
       # preference recorded yet", not "hide everything", so a visitor
       # who's never touched the Players page's Display panel keeps
       # seeing every column exactly as before this existed.
       visible: nil,
       # Set by `handle_params/3`, which Phoenix always calls after `mount/3`
       # (both the disconnected and the connected render) - `nil` here is
       # simply what a mount with no `?category=` in the URL would resolve
       # to anyway, kept as an explicit default so `reload_standings/1`
       # never reads an unassigned key on the very first call.
       selected_category: nil
     )
     |> reload_standings()}
  end

  # The category selector's own URL state (`?category=NAME`), read on every
  # mount and every `push_patch` from `handle_event("category_change", ...)`
  # below - see docs on that handler for why a patch rather than a plain
  # assign. A name the tournament does not (or no longer) list - a stale
  # link, a category since removed - falls back to "All players" instead of
  # showing an empty table with no way to tell why.
  @impl true
  def handle_params(params, _uri, socket) do
    tournament = socket.assigns.tournament
    requested = params["category"]

    selected =
      if is_binary(requested) and requested in (tournament.categories || []), do: requested

    {:noreply,
     assign(socket,
       selected_category: selected,
       filtered_entries: compute_filtered_entries(socket.assigns.entries, selected)
     )}
  end

  # Nothing here is user-editable except the manual-ranking controls below
  # - standings are otherwise read-only - so any broadcast can just refresh
  # everything, including the tournament (its tiebreak configuration drives
  # which columns are shown, and `manual_ranking` drives the banner/order).
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
        {:noreply, socket |> assign(tournament: tournament) |> reload_standings()}
    end
  end

  # SWAR parity #23 (manual standings override) - see docs/manual-standings.md
  # and PairingsEngine.Tournaments' "Manual standings override" section for
  # the seeding/staleness design. Not offered for Keizer tournaments (see
  # `reload_standings/1` below) so these handlers are unreachable from the
  # Keizer half of the page - nothing here needs to re-check `keizer?`.
  @impl true
  def handle_event("enable_manual_ranking", _params, socket) do
    case Tournaments.enable_manual_ranking(socket.assigns.tournament) do
      {:ok, tournament} ->
        Audit.log(
          tournament.id,
          socket.assigns.current_scope,
          "standings.manual_ranking_enabled",
          %{}
        )

        {:noreply, socket |> assign(tournament: tournament) |> reload_standings()}

      {:error, :archived} ->
        {:noreply, archived_refusal(socket)}
    end
  end

  @impl true
  def handle_event("disable_manual_ranking", _params, socket) do
    case Tournaments.disable_manual_ranking(socket.assigns.tournament) do
      {:ok, tournament} ->
        Audit.log(
          tournament.id,
          socket.assigns.current_scope,
          "standings.manual_ranking_disabled",
          %{}
        )

        {:noreply, socket |> assign(tournament: tournament) |> reload_standings()}

      {:error, :archived} ->
        {:noreply, archived_refusal(socket)}
    end
  end

  @impl true
  def handle_event("reseed_manual_ranking", _params, socket) do
    case Tournaments.reseed_manual_ranking(socket.assigns.tournament) do
      {:ok, tournament} ->
        Audit.log(tournament.id, socket.assigns.current_scope, "standings.manual_reseeded", %{})
        {:noreply, socket |> assign(tournament: tournament) |> reload_standings()}

      {:error, :archived} ->
        {:noreply, archived_refusal(socket)}
    end
  end

  # The "Standings after round K" control beside "Public page" - see the
  # `publish_controls/1` section below for K's own meaning and the two
  # handlers' shared reasoning with `PairingsEngineWeb.PairingsLive`'s
  # identical pair (same `Tournaments` functions, same rules 2/3).
  @impl true
  def handle_event("publish_standings", %{"round" => round}, socket) do
    tournament = socket.assigns.tournament
    round_number = String.to_integer(round)

    case Tournaments.publish_standings_through(tournament, round_number) do
      {:ok, tournament} ->
        Audit.log(tournament.id, socket.assigns.current_scope, "standings.published", %{
          through_round: round_number
        })

        {:noreply, socket |> assign(tournament: tournament) |> reload_standings()}

      {:error, :archived} ->
        {:noreply, archived_refusal(socket)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not change this"))}
    end
  end

  @impl true
  def handle_event("unpublish_standings", %{"round" => round}, socket) do
    tournament = socket.assigns.tournament
    round_number = String.to_integer(round)

    case Tournaments.unpublish_standings_through(tournament, round_number) do
      {:ok, tournament} ->
        Audit.log(tournament.id, socket.assigns.current_scope, "standings.unpublished", %{
          from_round: round_number
        })

        {:noreply, socket |> assign(tournament: tournament) |> reload_standings()}

      {:error, :archived} ->
        {:noreply, archived_refusal(socket)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not change this"))}
    end
  end

  @impl true
  def handle_event("manual_move", %{"player_id" => player_id, "direction" => direction}, socket)
      when direction in ["up", "down"] do
    tournament = socket.assigns.tournament
    direction = String.to_existing_atom(direction)

    # Tolerate a stale/crafted player_id (e.g. a row deleted in another tab)
    # gracefully instead of crashing the LiveView with Ecto.NoResultsError.
    case Tournaments.get_player(tournament.id, player_id) do
      nil ->
        {:noreply, socket}

      player ->
        do_manual_move(socket, tournament, player, direction)
    end
  end

  def handle_event("manual_move", _params, socket), do: {:noreply, socket}

  # Sent by the ColumnPrefs JS hook after reading localStorage - the same
  # hook and the same "pairingsengine.playerColumns" key PlayersLive's
  # Display panel already persists to, so ticking/unticking a column
  # there is reflected here too, without a second, separate preference to
  # keep in sync by hand.
  def handle_event("columns_loaded", %{"columns" => columns}, socket) when is_list(columns) do
    {:noreply, assign(socket, visible: columns)}
  end

  def handle_event("columns_loaded", _params, socket), do: {:noreply, socket}

  # `push_patch` rather than a plain `assign` so the choice lands in the URL
  # (`?category=NAME`) - it survives a reload and can be linked/bookmarked,
  # per the feature's own requirement. The patch round-trips through
  # `handle_params/3` above, which is the one place `selected_category` and
  # `filtered_entries` actually get set - this handler only decides the
  # target URL.
  def handle_event("category_change", %{"category" => value}, socket) do
    tournament = socket.assigns.tournament

    path =
      if value in [nil, ""],
        do: ~p"/t/#{tournament.id}/standings",
        else: ~p"/t/#{tournament.id}/standings?category=#{value}"

    {:noreply, push_patch(socket, to: path)}
  end

  ## ---------- the "Standings after round K" control ----------

  attr :tournament, Tournament, required: true
  attr :round_number, :integer, required: true
  # The already-loaded `%Round{}` for `round_number`, when one exists (`nil`
  # for round 0) - see `Tournaments.standings_publish_blocked_reason/3`'s own
  # doc on why the caller passes this rather than letting the check re-fetch.
  attr :round, :any, default: nil

  defp standings_publish_control(assigns) do
    ~H"""
    <.publish_toggle
      :if={@tournament.publish_mode == "immediate"}
      id={"standings-toggle-#{@round_number}"}
      label={gettext("Standings after round %{n}", n: @round_number)}
      state={:public}
      locked
      reason={
        gettext(
          "Standings publish automatically here, through the latest complete round. Change that in Settings → OpenResults."
        )
      }
    />

    <%= if @tournament.publish_mode != "immediate" do %>
      <% public? = Tournaments.standings_public?(@tournament, @round_number) %>
      <% blocked = Tournaments.standings_publish_blocked_reason(@tournament, @round_number, @round) %>
      <.publish_toggle
        id={"standings-toggle-#{@round_number}"}
        label={gettext("Standings after round %{n}", n: @round_number)}
        state={if public?, do: :public, else: :not_public}
        disabled={not public? and not is_nil(blocked)}
        reason={standings_reason_text(blocked, @round_number)}
        confirm={confirm_unpublish_standings(@tournament, @round_number)}
        phx-click={if public?, do: "unpublish_standings", else: "publish_standings"}
        phx-value-round={@round_number}
      />
    <% end %>
    """
  end

  # Same rule 3 confirm text as `PairingsEngineWeb.PairingsLive` - which
  # published rounds would go dark as a side effect of pulling standings
  # back (`Tournaments.unpublish_standings_through/2`'s own doc).
  defp confirm_unpublish_standings(tournament, round_number) do
    base =
      if round_number == 0 do
        gettext("Hide the entry list from the public page again?")
      else
        gettext(
          "Hide public standings after round %{n}? They will drop back to after round %{prev}.",
          n: round_number,
          prev: round_number - 1
        )
      end

    case lowest_published_round_above(tournament, round_number) do
      nil ->
        base

      hidden_from ->
        base <>
          " " <>
          gettext(
            "This also hides round %{n}'s pairings, and every round after it.",
            n: hidden_from
          )
    end
  end

  defp lowest_published_round_above(tournament, round_number) do
    tournament.id
    |> Tournaments.list_rounds()
    |> Enum.filter(&(&1.number > round_number and Tournaments.round_published?(tournament, &1)))
    |> Enum.map(& &1.number)
    |> case do
      [] -> nil
      numbers -> Enum.min(numbers)
    end
  end

  defp standings_reason_text(nil, _round_number), do: nil

  defp standings_reason_text(:not_paired, round_number),
    do: gettext("Round %{n} hasn't been paired yet.", n: round_number)

  defp standings_reason_text(:pairings_not_public, round_number),
    do: gettext("Round %{n}'s pairings aren't public yet - publish them first.", n: round_number)

  defp standings_reason_text(:round_not_complete, round_number),
    do:
      gettext(
        "Round %{n} isn't finished yet - every result must be entered first.",
        n: round_number
      )

  # An archived tournament refuses every write (Tournaments.ensure_writable/1).
  # These controls are hidden while archived, so reaching one of these clauses
  # means a stale tab or an event queued before the archive landed - say so
  # rather than crashing on the unmatched {:error, :archived}.
  defp archived_refusal(socket) do
    put_flash(socket, :error, "This tournament is archived - unarchive it to make changes.")
  end

  defp do_manual_move(socket, tournament, player, direction) do
    socket =
      case Tournaments.move_manual_rank(tournament, player, direction) do
        {:ok, _} ->
          Audit.log(tournament.id, socket.assigns.current_scope, "standings.manual_reorder", %{
            player_id: player.id,
            player_name: player.name,
            direction: to_string(direction)
          })

          assign(socket, tournament: %{tournament | manual_ranking_stale: false})

        {:error, :archived} ->
          archived_refusal(socket)

        {:error, _} ->
          socket
      end

    {:noreply, reload_standings(socket)}
  end

  # Keizer tournaments show their own ladder (rank/value/Keizer points)
  # instead of the FIDE-tiebreak table - see PairingsEngine.Keizer.standings/1
  # and docs/pairing-systems.md. Everything else on this page (PubSub
  # refresh, the print/public links) is unaffected either way.
  #
  # Manual ranking (SWAR parity #23) is deliberately not offered for Keizer
  # - its ladder is recomputed on the fly every render and stored nowhere
  # (see docs/manual-standings.md for the reasoning), so `entries` only
  # ever gets `Standings.apply_manual_ranking/2` applied on the non-Keizer
  # branch, and the manual-ranking assigns below are simply `false`/`[]`
  # for a Keizer tournament - the template never shows the banner/controls.
  defp reload_standings(socket) do
    tournament = socket.assigns.tournament
    keizer? = tournament.pairing_system == "keizer"

    # Recomputed on every refresh, not read once at mount: C.07 Article 10
    # turns on whether an unrated player is PRESENT, and a player can be
    # added mid-event. Computing it here means the broadcast that already
    # reloads the table drops the column too, instead of leaving a stale one
    # until somebody reloads the page.
    socket =
      assign(socket,
        effective_tiebreaks: Standings.effective_tiebreaks(tournament),
        dropped_tiebreaks: Standings.dropped_tiebreaks_with_reasons(tournament)
      )

    entries =
      if keizer? do
        Keizer.standings(tournament)
      else
        tournament
        |> Standings.standings()
        |> with_expected_score()
        |> Standings.apply_manual_ranking(tournament)
      end

    selected_category = Map.get(socket.assigns, :selected_category)
    latest_complete_round = Tournaments.latest_complete_round(tournament)

    assign(socket,
      keizer?: keizer?,
      entries: entries,
      filtered_entries: compute_filtered_entries(entries, selected_category),
      category_places: category_places_by_name(tournament, entries),
      rounds_paired: Standings.rounds_paired(tournament.id),
      latest_complete_round: latest_complete_round,
      # Loaded alongside the number rather than re-fetched inside the
      # component (see `Tournaments.standings_publish_blocked_reason/3`'s
      # own doc on the optional preloaded round) - one query per reload
      # instead of one per render, and one fewer place for two reads of the
      # same round in the same pass to ever disagree.
      latest_complete_round_struct:
        if(latest_complete_round > 0,
          do: Tournaments.get_round(tournament.id, latest_complete_round)
        ),
      manual_stale?:
        !keizer? and tournament.manual_ranking and Standings.manual_ranking_stale?(tournament),
      manual_incomplete?:
        !keizer? and tournament.manual_ranking and Standings.manual_ranking_incomplete?(entries)
    )
  end

  # The category selector's filtered view - `entries`, cut down to one
  # category and renumbered 1..n by `Categories.category_places/2`. `nil`
  # (rather than an empty list) for "All players" so the template can tell
  # "no filter" apart from "this category genuinely has nobody in it".
  defp compute_filtered_entries(_entries, nil), do: nil

  defp compute_filtered_entries(entries, category),
    do: Categories.category_places(entries, category)

  # Every category's place, for every player who is in it -
  # `%{category_name => %{player_id => place}}` - computed once per reload
  # rather than once per row: the Category column's chips (unfiltered view)
  # need every one of a player's categories' places at once, and
  # `Categories.category_places/2` itself is an O(n) pass per category.
  defp category_places_by_name(tournament, entries) do
    Map.new(tournament.categories || [], fn name ->
      places =
        entries |> Categories.category_places(name) |> Map.new(&{&1.player.id, &1.category_place})

      {name, places}
    end)
  end

  # Attaches `:we` / `:wmwe` (FIDE expected score / W−We, Table 8.1.2) to
  # every entry - same computation as the Players page grid
  # (`PairingsEngineWeb.PlayersLive.build_grid/2`): only played games
  # against a rated opponent count, own rating unrated or zero counted
  # games renders blank. Not offered for Keizer standings - Keizer scoring
  # isn't rating-based, so an "expected score" has no meaning there.
  defp with_expected_score(entries) do
    players_by_id = Map.new(entries, &{&1.player.id, &1.player})

    Enum.map(entries, fn entry ->
      played_games = Enum.filter(entry.games, & &1.played)

      rated_games =
        Enum.filter(played_games, fn g ->
          case Map.get(players_by_id, g.opponent_id) do
            nil -> false
            opp -> Player.rating(opp) > 0
          end
        end)

      own_rating = Player.rating(entry.player)

      opponent_ratings =
        Enum.map(rated_games, &Player.rating(Map.get(players_by_id, &1.opponent_id)))

      we = PlayerStats.we(own_rating, opponent_ratings)
      w_counted = rated_games |> Enum.map(& &1.points) |> Enum.sum()

      Map.merge(entry, %{we: we, wmwe: PlayerStats.w_minus_we(w_counted, we)})
    end)
  end

  defp format_tb(value) when is_float(value) do
    if value == Float.round(value, 0), do: trunc(value), else: value
  end

  defp format_tb(value), do: value

  # Every category `entry.player` is in, in the tournament's own order, each
  # with its in-category place (from `@category_places`, built by
  # `category_places_by_name/2`) and whether that place is a prize place -
  # the Category column's chips, one `{name, place, prize?}` triple per
  # category. `place` is `nil` only if `entry.player` somehow is not
  # actually one of `@entries` (defensive; cannot happen through this
  # page's own data flow).
  defp category_chips(tournament, entry, category_places) do
    tournament
    |> Categories.listed_categories(entry.player)
    |> Enum.map(fn name ->
      place = get_in(category_places, [name, entry.player.id])
      {name, place, place != nil and Categories.prize_place?(tournament, name, place)}
    end)
  end

  # The category selector's header line - "U1800 - 3 prizes" when a prize
  # count is configured for the selected category, the bare name otherwise.
  defp category_header_text(tournament, name) do
    case Map.get(tournament.category_prizes || %{}, name) do
      count when is_integer(count) and count > 0 ->
        ngettext(
          "%{category} - %{count} prize",
          "%{category} - %{count} prizes",
          count,
          category: name,
          count: count
        )

      _ ->
        name
    end
  end

  defp sex_display(sex) do
    case Player.sex_label(sex) do
      "" -> "-"
      label -> label
    end
  end

  defp format_we(nil), do: "-"
  defp format_we(n), do: :erlang.float_to_binary(n / 1, decimals: 2)

  defp format_wmwe(nil), do: "-"

  defp format_wmwe(n) do
    sign = if n >= 0, do: "+", else: ""
    sign <> :erlang.float_to_binary(n / 1, decimals: 2)
  end

  # `nil` (ColumnPrefs hasn't reported back yet, or the arbiter has never
  # touched the Players page's Display panel at all) means "no preference
  # recorded" - show everything, same as before this existed - not "hide
  # everything".
  defp show_col?(nil, _key), do: true
  defp show_col?(visible, key), do: key in visible

  # A tiebreak code with no Players-grid equivalent (WIN/KS/MP/GP/BB - team
  # or round-robin-only breaks the grid never offers a toggle for at all)
  # always shows: there's no preference to defer to.
  defp show_tiebreak?(visible, code) do
    case Tiebreaks.grid_key(code) do
      nil -> true
      key -> show_col?(visible, key)
    end
  end

  defp visible_tiebreak_codes(tiebreaks, visible),
    do: Enum.filter(tiebreaks, &show_tiebreak?(visible, &1))

  # Groups `[{code, reason}]` into `[{reason, [code, ...]}]`, keeping the
  # reasons in a fixed order so the paragraphs do not reshuffle between
  # renders.
  @drop_reason_order [:not_calculable, :unrated_present]

  defp dropped_by_reason(dropped) do
    grouped = Enum.group_by(dropped, &elem(&1, 1), &elem(&1, 0))

    for reason <- @drop_reason_order, codes = grouped[reason], codes not in [nil, []] do
      {reason, codes}
    end
  end

  defp dropped_reason_text(:not_calculable) do
    gettext(
      "OpenPairings cannot calculate this yet: it needs team standings, which are not built. It would score zero for every player and separate nobody, so it is left out of the ranking rather than shown as a column of noughts. Pick a different tie-break here."
    )
  end

  defp dropped_reason_text(:unrated_present) do
    gettext(
      "This tournament has at least one unrated player, and C.07 Article 10 drops rating-based tie-breaks when that is the case - an unrated opponent has no rating to average, and FIDE gives no number to use instead. It can be used if your tournament regulations, or the Chief Arbiter before the first round, published a rule for handling unrated players; set that out and pick a different tie-break here."
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      publish_status={assigns[:publish_status]}
      update_notice={assigns[:update_notice]}
      flash={@flash}
      current_path={assigns[:current_path]}
      current_scope={@current_scope}
      tournament={@tournament}
      active="standings"
    >
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>

          <p class="subtitle" style="margin: 0">
            {cond do
              @selected_category -> category_header_text(@tournament, @selected_category)
              @rounds_paired > 0 -> gettext("Standings after round %{n}", n: @rounds_paired)
              true -> gettext("Standings")
            end}
          </p>
        </div>

        <div class="actions" style="margin: 0">
          <a
            :if={PublicLink.public?(@tournament)}
            class="pe-btn"
            href={PublicLink.url(@tournament, :standings)}
            target="_blank"
            title={gettext("Opens the results site - no login needed, share this link")}
          >
            {gettext("Public page")}
          </a>

          <%!-- Beside "Public page" because that is the page it changes, and
                only while there is one: a tournament that does not publish has
                nothing for it to show or hide. `@latest_complete_round` is the
                round this control targets - the entry list (round 0) before
                round 1 has a single result, otherwise the latest round that is
                actually complete (`Tournaments.latest_complete_round/1`); the
                control itself still refuses (disabled, with a reason) unless
                that round's own pairings are already public too. --%>
          <.standings_publish_control
            :if={PublicLink.public?(@tournament)}
            tournament={@tournament}
            round_number={@latest_complete_round}
            round={@latest_complete_round_struct}
          />

          <a class="pe-btn" href={~p"/t/#{@tournament.id}/print/standings"} target="_blank">
            {gettext("Print")}
          </a>
        </div>
      </div>

      <%!-- Above the table, per the feature's own spec - applies to both the
            FIDE-tiebreak table and the Keizer ladder below, so it sits above
            both rather than being duplicated inside each. The choice lives in
            the URL (`?category=NAME`, via `handle_event("category_change",
            ...)`'s `push_patch`), so it survives a reload and can be
            linked/bookmarked. --%>
      <div :if={@tournament.categories != []} class="card" style="margin-bottom: 12px">
        <label style="display: flex; align-items: center; gap: 10px">
          <span class="set-label" style="margin: 0">{gettext("Category")}</span>
          <select name="category" phx-change="category_change">
            <option value="" selected={is_nil(@selected_category)}>{gettext("All players")}</option>
            <option :for={c <- @tournament.categories} value={c} selected={@selected_category == c}>
              {c}
            </option>
          </select>
        </label>
      </div>

      <div :if={!@keizer?} class="card manual-ranking-card" style="margin-bottom: 12px">
        <div
          :if={@tournament.manual_ranking}
          class="manual-ranking-banner"
          style="margin-bottom: 8px; padding: 8px 12px; border: 2px solid var(--warn); border-radius: 6px;"
        >
          <strong>{gettext("Manual ranking is ON.")}</strong>
          {gettext(
            "The rank column below reflects the arbiter's hand-set order, not the computed tiebreak order - this also applies on the public standings page, printed standings, and the TRF export."
          )}
          <span :if={@manual_incomplete?}>
            {gettext(
              "A player was added after this was turned on and hasn't been placed yet - new players sort last until you re-seed."
            )}
          </span>

          <span :if={@manual_stale?}>
            <strong>{gettext(
              "A result changed since this order was last set - it may no longer match the real standings."
            )}</strong>
          </span>
        </div>

        <%!-- Every control here writes, so the whole row is hidden while the
              tournament is archived - the layout's archived banner already
              explains why. The handlers still refuse defensively. --%>
        <div :if={!@tournament.archived_at} class="actions" style="margin: 0">
          <button
            :if={!@tournament.manual_ranking}
            class="pe-btn"
            phx-click="enable_manual_ranking"
            data-confirm={
              gettext(
                "Switch to manual ranking? The current computed order will be used as the starting point."
              )
            }
          >
            {gettext("Enable manual ranking")}
          </button>

          <button :if={@tournament.manual_ranking} class="pe-btn" phx-click="disable_manual_ranking">
            {gettext("Disable manual ranking")}
          </button>

          <button
            :if={@tournament.manual_ranking and (@manual_stale? or @manual_incomplete?)}
            class="pe-btn"
            phx-click="reseed_manual_ranking"
          >
            {gettext("Re-seed from current order")}
          </button>
        </div>
      </div>

      <div :if={@entries == []} class="card empty">
        <p><strong>{gettext("No players registered yet.")}</strong></p>
      </div>

      <%!-- One paragraph per REASON, not per code: two tie-breaks dropped for
            the same reason read as one sentence, and two dropped for
            different reasons must not be explained by whichever reason
            happened to be written into the markup. --%>
      <p
        :for={{reason, codes} <- dropped_by_reason(@dropped_tiebreaks)}
        class="hint"
        style="margin-bottom: 10px"
      >
        <strong>
          {ngettext(
            "%{codes} is not being used.",
            "%{codes} are not being used.",
            length(codes),
            codes: Enum.join(codes, ", ")
          )}
        </strong>
        {dropped_reason_text(reason)}
      </p>

      <div
        :if={@entries != [] and !@keizer?}
        id="standings-table"
        class="card table-card"
        phx-hook="ColumnPrefs"
      >
        <% display_entries = @filtered_entries || @entries %>
        <table class="pe-table">
          <thead>
            <tr>
              <th class="num">
                {if @selected_category, do: gettext("Place"), else: gettext("Rank")}
              </th>

              <th>{gettext("Name")}</th>

              <th :if={show_col?(@visible, "sex")}>Sex</th>

              <th class="num">Elo</th>

              <th class="num">Pts</th>

              <th
                :if={@tournament.count_extra_points and show_col?(@visible, "xtpts")}
                class="num"
                title={gettext("Administrative bonus points (SWAR XtPts)")}
              >
                XtPts
              </th>

              <th
                :if={@tournament.count_extra_points and show_col?(@visible, "ptot")}
                class="num"
                title={gettext("Points + extra points - this is what ranking sorts by")}
              >
                {gettext("Total")}
              </th>

              <th
                :if={show_col?(@visible, "we")}
                class="num"
                title={gettext("FIDE expected score (Table 8.1.2)")}
              >
                We
              </th>

              <th
                :if={show_col?(@visible, "wmwe")}
                class="num"
                title={gettext("Actual score minus expected score")}
              >
                {gettext("W-We")}
              </th>

              <th
                :for={code <- visible_tiebreak_codes(@effective_tiebreaks, @visible)}
                class="num"
                title={tb_name(code)}
              >
                {code}
              </th>

              <th :if={@tournament.categories != [] and is_nil(@selected_category)}>
                {gettext("Category")}
              </th>

              <th :if={@tournament.manual_ranking and is_nil(@selected_category)}>
                {gettext("Reorder")}
              </th>
            </tr>
          </thead>

          <tbody>
            <tr :for={entry <- display_entries}>
              <% place = Map.get(entry, :category_place) || entry.rank %>
              <% prize? =
                @selected_category && Categories.prize_place?(@tournament, @selected_category, place) %>
              <td class={["num", prize? && "pe-cat-place is-prize"]}>{place}</td>

              <td>
                <strong>
                  {if entry.player.title != "", do: "#{entry.player.title} "}{entry.player.name}
                </strong>
              </td>

              <td :if={show_col?(@visible, "sex")}>{sex_display(entry.player.sex)}</td>

              <td class="num">
                {if Player.rating(entry.player) > 0, do: Player.rating(entry.player), else: "-"}
              </td>

              <td class="num"><strong>{entry.points}</strong></td>

              <td :if={@tournament.count_extra_points and show_col?(@visible, "xtpts")} class="num">
                {entry.extra_points}
              </td>

              <td :if={@tournament.count_extra_points and show_col?(@visible, "ptot")} class="num">
                <strong>{entry.total}</strong>
              </td>

              <td :if={show_col?(@visible, "we")} class="num">{format_we(entry.we)}</td>

              <td :if={show_col?(@visible, "wmwe")} class="num">{format_wmwe(entry.wmwe)}</td>

              <td :for={code <- visible_tiebreak_codes(@effective_tiebreaks, @visible)} class="num">
                {format_tb(Map.get(entry.tiebreaks, code, 0.0))}
              </td>

              <td :if={@tournament.categories != [] and is_nil(@selected_category)}>
                <% chips = category_chips(@tournament, entry, @category_places) %>
                <span :if={chips == []}>-</span>
                <span
                  :for={{name, chip_place, chip_prize?} <- chips}
                  class={["pe-cat-chip", chip_prize? && "is-prize"]}
                >
                  {name}{if chip_place, do: " · #{chip_place}"}
                </span>
              </td>

              <td :if={@tournament.manual_ranking and is_nil(@selected_category)}>
                <button
                  class="pe-btn"
                  style="padding: 2px 9px; font-size: 13px;"
                  phx-click="manual_move"
                  phx-value-player_id={entry.player.id}
                  phx-value-direction="up"
                  aria-label={"Move #{entry.player.name} up"}
                  disabled={!is_nil(@tournament.archived_at)}
                >
                  ↑
                </button>

                <button
                  class="pe-btn"
                  style="padding: 2px 9px; font-size: 13px;"
                  phx-click="manual_move"
                  phx-value-player_id={entry.player.id}
                  phx-value-direction="down"
                  aria-label={"Move #{entry.player.name} down"}
                  disabled={!is_nil(@tournament.archived_at)}
                >
                  ↓
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <p :if={@rounds_paired == 0 and !@keizer?} class="hint">
        {gettext(
          "Tiebreak columns fill in as results are entered, following the FIDE Tie-Break Regulations in the order set under Settings."
        )}
      </p>

      <div :if={@entries != [] and @keizer?} class="card table-card">
        <% display_entries = @filtered_entries || @entries %>
        <table class="pe-table">
          <thead>
            <tr>
              <th class="num">
                {if @selected_category, do: gettext("Place"), else: gettext("Rank")}
              </th>

              <th>{gettext("Name")}</th>

              <th :if={show_col?(@visible, "sex")}>Sex</th>

              <th class="num">Elo</th>

              <th class="num">{gettext("Value")}</th>

              <th class="num">{gettext("Keizer pts")}</th>

              <th class="num">{gettext("Score")}</th>

              <th :if={@tournament.categories != [] and is_nil(@selected_category)}>
                {gettext("Category")}
              </th>
            </tr>
          </thead>

          <tbody>
            <tr :for={entry <- display_entries}>
              <% place = Map.get(entry, :category_place) || entry.rank %>
              <% prize? =
                @selected_category && Categories.prize_place?(@tournament, @selected_category, place) %>
              <td class={["num", prize? && "pe-cat-place is-prize"]}>{place}</td>

              <td>
                <strong>
                  {if entry.player.title != "", do: "#{entry.player.title} "}{entry.player.name}
                </strong>
              </td>

              <td :if={show_col?(@visible, "sex")}>{sex_display(entry.player.sex)}</td>

              <td class="num">
                {if Player.rating(entry.player) > 0, do: Player.rating(entry.player), else: "-"}
              </td>

              <td class="num">{entry.value}</td>

              <td class="num"><strong>{entry.points}</strong></td>

              <td class="num">{entry.raw_points}</td>

              <td :if={@tournament.categories != [] and is_nil(@selected_category)}>
                <% chips = category_chips(@tournament, entry, @category_places) %>
                <span :if={chips == []}>-</span>
                <span
                  :for={{name, chip_place, chip_prize?} <- chips}
                  class={["pe-cat-chip", chip_prize? && "is-prize"]}
                >
                  {name}{if chip_place, do: " · #{chip_place}"}
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <p :if={@keizer?} class="hint">
        {gettext(
          "Keizer points, not FIDE tiebreaks - the whole ladder is recalculated from results, byes and absences every time (see docs/pairing-systems.md)."
        )}
      </p>
    </Layouts.app>
    """
  end

  defp tb_name(code), do: (Tiebreaks.get(code) || %{name: code}).name
end
