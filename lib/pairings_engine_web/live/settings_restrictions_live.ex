defmodule PairingsEngineWeb.SettingsRestrictionsLive do
  @moduledoc """
  The "Forbidden pairings" settings page (`/t/:id/settings/restrictions`):
  who must not meet whom, and how hard the engine tries.

    * **Rules** - "players of the same club do not meet", "same federation",
      each a rule or a wish ("if possible"), for every round or a window of
      them (`PairingRule`). Expanded from the players as they are when a
      round is paired, so nobody maintains them when the roster changes.
    * **Players** - pick any number of players at once and keep them apart:
      two is a forbidden pair, three or more a group rule. Pairs and groups
      are edited and removed in place.
    * **Effect** - what the hard ones do to the next round before anybody
      presses Pair: the games ruled out, players left with nobody, and
      whether the round can be paired at all (`RestrictionCheck`).

  In FIDE mode these are set before round 1 is paired (C.05 5.2). Once it is,
  every add, change or remove asks twice (TEC's Level 4) and takes the
  tournament out of FIDE mode (`Tournaments.record_prohibition_change/2`).
  The page asks; the context records.
  """
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport

  alias PairingsEngine.{Audit, Compliance, Exclusions, RestrictionCheck, Tournaments}
  alias PairingsEngine.Tournaments.{PairingRule, Player, Tournament}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    {:ok,
     socket
     |> attach_fide_gate()
     |> assign(
       tournament: tournament,
       page_title: "#{tournament.name} · " <> gettext("Forbidden pairings"),
       query: "",
       selected: [],
       selection_soft: false,
       editing_group: nil,
       editing_rule: nil,
       rule_form: rule_form(%{}),
       edit_form: nil,
       error: nil,
       rule_error: nil,
       note: nil
     )
     |> load()}
  end

  defp load(socket) do
    tournament = socket.assigns.tournament

    players =
      tournament.id |> Tournaments.list_players() |> Enum.sort_by(&String.downcase(&1.name))

    by_id = Map.new(players, &{&1.id, &1})
    rules = Tournaments.list_pairing_rules(tournament.id)
    {groups, field_rules} = Enum.split_with(rules, &(&1.kind == "group"))

    assign(socket,
      players: players,
      players_by_id: by_id,
      pairs: Tournaments.list_forbidden_pairings(tournament.id),
      field_rules: field_rules,
      groups: groups,
      effects: Map.new(rules, &{&1.id, Exclusions.effect(&1, players)}),
      check: RestrictionCheck.next_round(tournament),
      paired: PairingsEngine.Pairing.paired_rounds_count(tournament.id),
      departs?: Tournaments.prohibition_change_departs?(tournament)
    )
  end

  defp reload(socket) do
    tournament =
      Tournaments.get_authorized_tournament!(
        socket.assigns.current_scope,
        socket.assigns.tournament.id
      )

    socket |> assign(tournament: tournament) |> load()
  end

  @impl true
  def handle_info({:tournament_changed, _id, _hint}, socket) do
    case Tournaments.get_authorized_tournament(
           socket.assigns.current_scope,
           socket.assigns.tournament.id
         ) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("This tournament was deleted."))
         |> push_navigate(to: ~p"/")}

      tournament ->
        {:noreply, socket |> assign(tournament: tournament) |> load()}
    end
  end

  ## ---------- the player picker ----------

  @impl true
  def handle_event("search", %{"q" => q}, socket),
    do: {:noreply, assign(socket, query: String.slice(q, 0, 100))}

  def handle_event("toggle_player", %{"id" => id}, socket) do
    with {id, ""} <- Integer.parse(to_string(id)),
         true <- Map.has_key?(socket.assigns.players_by_id, id) do
      selected = socket.assigns.selected

      selected =
        if id in selected, do: List.delete(selected, id), else: selected ++ [id]

      {:noreply, assign(socket, selected: selected, error: nil)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("clear_selection", _params, socket),
    do:
      {:noreply,
       assign(socket, selected: [], editing_group: nil, selection_soft: false, error: nil)}

  def handle_event("selection_soft", params, socket),
    do: {:noreply, assign(socket, selection_soft: params["soft"] == "true")}

  def handle_event("keep_apart", params, socket) do
    with :proceed <- ask(socket, "keep_apart", params) do
      soft? = params["soft"] == "true"
      t = socket.assigns.tournament
      ids = socket.assigns.selected

      result =
        case socket.assigns.editing_group do
          nil ->
            Tournaments.add_forbidden_group(t, ids, soft: soft?)

          group_id ->
            Tournaments.update_pairing_rule(t, group_id, %{
              "player_ids" => ids,
              "soft" => soft?
            })
        end

      case result do
        {:ok, row} ->
          {:noreply,
           socket
           |> audit_row(row, if(socket.assigns.editing_group, do: "changed", else: "added"))
           |> assign(selected: [], editing_group: nil, selection_soft: false, error: nil)
           |> after_change(t)}

        {:error, reason} ->
          {:noreply, assign(socket, error: picker_error(reason))}
      end
    end
  end

  def handle_event("edit_group", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.groups, &(to_string(&1.id) == to_string(id))) do
      nil ->
        {:noreply, socket}

      group ->
        {:noreply,
         assign(socket,
           editing_group: group.id,
           selected:
             Enum.filter(group.player_ids, &Map.has_key?(socket.assigns.players_by_id, &1)),
           selection_soft: group.soft,
           error: nil
         )}
    end
  end

  def handle_event("set_pair_soft", %{"id" => id, "soft" => soft} = params, socket) do
    with :proceed <- ask(socket, "set_pair_soft", params),
         {id, ""} <- Integer.parse(to_string(id)) do
      t = socket.assigns.tournament

      case Tournaments.set_forbidden_pairing_soft(t, id, soft == "true") do
        {:ok, row} ->
          {:noreply, socket |> audit_row(row, "changed") |> after_change(t)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, error_text(reason))}
      end
    else
      {:noreply, _} = halted -> halted
      _ -> {:noreply, socket}
    end
  end

  def handle_event("remove_pair", %{"id" => id} = params, socket) do
    with :proceed <- ask(socket, "remove_pair", params) do
      t = socket.assigns.tournament

      case Tournaments.remove_forbidden_pairing(t, id) do
        {:ok, row} -> {:noreply, socket |> audit_row(row, "removed") |> after_change(t)}
        {:error, reason} -> {:noreply, put_flash(socket, :error, error_text(reason))}
      end
    end
  end

  ## ---------- rules ----------

  def handle_event("rule_change", %{"rule" => params}, socket),
    do: {:noreply, assign(socket, rule_form: rule_form(params))}

  def handle_event("add_rule", %{"rule" => params} = payload, socket) do
    with :proceed <- ask(socket, "add_rule", payload) do
      t = socket.assigns.tournament

      case Tournaments.add_pairing_rule(t, rule_attrs(params)) do
        {:ok, rule} ->
          {:noreply,
           socket
           |> audit_row(rule, "added")
           |> assign(rule_form: rule_form(%{}), rule_error: nil)
           |> after_change(t)}

        {:error, reason} ->
          {:noreply, assign(socket, rule_form: rule_form(params), rule_error: rule_error(reason))}
      end
    end
  end

  def handle_event("edit_rule", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.field_rules, &(to_string(&1.id) == to_string(id))) do
      nil ->
        {:noreply, socket}

      rule ->
        {:noreply,
         assign(socket,
           editing_rule: rule.id,
           edit_form: rule_form(rule_params(rule)),
           rule_error: nil
         )}
    end
  end

  def handle_event("cancel_edit_rule", _params, socket),
    do: {:noreply, assign(socket, editing_rule: nil, edit_form: nil, rule_error: nil)}

  def handle_event("edit_rule_change", %{"rule" => params}, socket),
    do: {:noreply, assign(socket, edit_form: rule_form(params))}

  def handle_event("update_rule", %{"rule" => params} = payload, socket) do
    with :proceed <- ask(socket, "update_rule", payload) do
      t = socket.assigns.tournament

      case Tournaments.update_pairing_rule(t, socket.assigns.editing_rule, rule_attrs(params)) do
        {:ok, rule} ->
          {:noreply,
           socket
           |> audit_row(rule, "changed")
           |> assign(editing_rule: nil, edit_form: nil, rule_error: nil)
           |> after_change(t)}

        {:error, reason} ->
          {:noreply, assign(socket, edit_form: rule_form(params), rule_error: rule_error(reason))}
      end
    end
  end

  def handle_event("remove_rule", %{"id" => id} = params, socket) do
    with :proceed <- ask(socket, "remove_rule", params) do
      t = socket.assigns.tournament

      case Tournaments.delete_pairing_rule(t, id) do
        {:ok, rule} ->
          {:noreply,
           socket
           |> audit_row(rule, "removed")
           |> assign(editing_group: nil, selected: [])
           |> after_change(t)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, error_text(reason))}
      end
    end
  end

  ## ---------- how hard wishes are tried ----------

  def handle_event("save_soft_position", %{"tournament" => params} = payload, socket) do
    params = Map.take(params, ["soft_position"])
    base = Tournaments.get_tournament!(socket.assigns.tournament.id)

    with :proceed <- fide_gate(socket, "save_soft_position", payload, base, params) do
      case Tournaments.update_tournament(base, params) do
        {:ok, tournament} ->
          log_settings_change(socket, base, tournament)

          if is_nil(base.fide_compliance_lost_round) and tournament.fide_compliance_lost_round,
            do: log_departure(socket, tournament)

          {:noreply,
           socket
           |> assign(tournament: tournament, note: gettext("Saved."))
           |> load()}

        {:error, changeset} ->
          {:noreply, assign(socket, error: error_text(changeset))}
      end
    end
  end

  ## ---------- helpers ----------

  # TEC's Level 4 before an act that would take the tournament out of FIDE
  # mode; `:proceed` otherwise, or once the arbiter has answered twice.
  defp ask(socket, event, params) do
    if socket.assigns.fide_gate_confirmed or
         not Tournaments.prohibition_change_departs?(socket.assigns.tournament) do
      :proceed
    else
      {:noreply, assign(socket, fide_gate: new_gate(event, params, [prohibition_reason()]))}
    end
  end

  defp prohibition_reason,
    do:
      {gettext("Forbidden pairings"),
       gettext(
         "Round 1 is paired. The FIDE rules (C.05 5.2) want every restriction on the pairings announced before the first round; adding, changing or removing one now is not something they allow."
       )}

  # Reloads, and writes the trail's copy of the stamp when this act is the
  # one that left FIDE mode (as `SettingsSupport.log_compliance_departures/3`
  # does for a settings save).
  defp after_change(socket, before) do
    socket = reload(socket)
    after_t = socket.assigns.tournament

    if is_nil(before.fide_compliance_lost_round) and after_t.fide_compliance_lost_round != nil,
      do: log_departure(socket, after_t)

    socket
  end

  defp log_departure(socket, tournament) do
    Audit.log(tournament.id, socket.assigns.current_scope, "tournament.fide_compliance_lost", %{
      setting: "forbidden_pairings",
      code: "prohibition_changed_after_round_1",
      round: tournament.fide_compliance_lost_round
    })
  end

  # One clause per action, each writing its code as a literal, so the
  # audit-code guard (`AuditActionCodes`) reads every code this page can
  # write straight off the source.
  defp audit_row(socket, %PairingsEngine.Tournaments.ForbiddenPairing{} = row, "added"),
    do: log(socket, "forbidden_pairing.added", pair_details(row))

  defp audit_row(socket, %PairingsEngine.Tournaments.ForbiddenPairing{} = row, "changed"),
    do: log(socket, "forbidden_pairing.changed", pair_details(row))

  defp audit_row(socket, %PairingsEngine.Tournaments.ForbiddenPairing{} = row, "removed"),
    do: log(socket, "forbidden_pairing.removed", pair_details(row))

  defp audit_row(socket, %PairingRule{} = rule, "added"),
    do: log(socket, "pairing_rule.added", rule_details(rule))

  defp audit_row(socket, %PairingRule{} = rule, "changed"),
    do: log(socket, "pairing_rule.changed", rule_details(rule))

  defp audit_row(socket, %PairingRule{} = rule, "removed"),
    do: log(socket, "pairing_rule.removed", rule_details(rule))

  defp log(socket, action, details) do
    Audit.log(socket.assigns.tournament.id, socket.assigns.current_scope, action, details)
    socket
  end

  defp pair_details(row),
    do: %{player_a_id: row.player_a_id, player_b_id: row.player_b_id, soft: row.soft}

  defp rule_details(rule),
    do: %{
      rule: Exclusions.describe(rule),
      kind: rule.kind,
      soft: rule.soft,
      player_ids: rule.player_ids
    }

  defp picker_error(:same_player), do: gettext("Choose at least two players.")
  defp picker_error(:invalid_player), do: gettext("Choose players from this tournament.")
  defp picker_error(:already_forbidden), do: gettext("Those two are already kept apart.")
  defp picker_error(%Ecto.Changeset{} = cs), do: error_text(cs)
  defp picker_error(reason), do: error_text(reason)

  defp rule_error(%Ecto.Changeset{} = cs), do: error_text(cs)
  defp rule_error(reason), do: error_text(reason)

  @rule_defaults %{
    "kind" => "club",
    "names" => "",
    "soft" => "false",
    "window" => "all",
    "window_rounds" => "",
    "window_from" => "",
    "window_to" => ""
  }

  defp rule_form(params),
    do: to_form(Map.merge(@rule_defaults, Map.take(params, Map.keys(@rule_defaults))), as: :rule)

  defp rule_params(rule),
    do: %{
      "kind" => rule.kind,
      "names" => Enum.join(rule.names, ", "),
      "soft" => to_string(rule.soft),
      "window" => rule.window,
      "window_rounds" => to_string(rule.window_rounds || ""),
      "window_from" => to_string(rule.window_from || ""),
      "window_to" => to_string(rule.window_to || "")
    }

  defp rule_attrs(params) do
    kind = if params["kind"] in ["club", "federation"], do: params["kind"], else: "club"

    %{
      "kind" => kind,
      "names" => Exclusions.normalize_list(params["names"] || ""),
      "soft" => params["soft"] == "true",
      "window" => params["window"] || "all",
      "window_rounds" => blank_nil(params["window_rounds"]),
      "window_from" => blank_nil(params["window_from"]),
      "window_to" => blank_nil(params["window_to"])
    }
  end

  defp blank_nil(v) when v in [nil, ""], do: nil
  defp blank_nil(v), do: v

  defp filtered(players, query) do
    case query |> String.trim() |> String.downcase() do
      "" ->
        players

      q ->
        Enum.filter(players, fn p ->
          Enum.any?(
            [p.name, p.club, p.federation],
            &String.contains?(String.downcase(&1 || ""), q)
          )
        end)
    end
  end

  defp kind_label("club"), do: gettext("Same club")
  defp kind_label("federation"), do: gettext("Same federation")
  defp kind_label(_), do: gettext("Group")

  defp rule_title(rule) do
    case rule.names do
      [] -> kind_label(rule.kind)
      names -> kind_label(rule.kind) <> ": " <> Enum.join(names, ", ")
    end
  end

  defp window_label(rule, tournament) do
    base =
      case rule.window do
        "first" ->
          ngettext("First round", "First %{count} rounds", rule.window_rounds || 0)

        "last" ->
          ngettext("Last round", "Last %{count} rounds", rule.window_rounds || 0)

        "range" ->
          gettext("Rounds %{from}-%{to}", from: rule.window_from, to: rule.window_to)

        _ ->
          gettext("Every round")
      end

    case Exclusions.rounds(rule, tournament.rounds_count) do
      nil ->
        base <> " · " <> gettext("no round left")

      {first, last}
      when rule.window == "last" or (is_integer(rule.from_round) and rule.from_round > 1) ->
        base <> " · " <> span_text(first, last || tournament.rounds_count)

      _ ->
        base
    end
  end

  defp span_text(first, last) when first == last, do: gettext("round %{n}", n: first)
  defp span_text(first, last), do: gettext("rounds %{from}-%{to}", from: first, to: last)

  defp effect_text(%{kind: "club"}, %{pairs: pairs, groups: groups}),
    do:
      ngettext("%{count} pair", "%{count} pairs", pairs) <>
        " " <> ngettext("in %{count} club", "among %{count} clubs", groups)

  defp effect_text(%{kind: "federation"}, %{pairs: pairs, groups: groups}),
    do:
      ngettext("%{count} pair", "%{count} pairs", pairs) <>
        " " <> ngettext("in %{count} federation", "among %{count} federations", groups)

  defp effect_text(_rule, %{pairs: pairs}), do: ngettext("%{count} pair", "%{count} pairs", pairs)

  defp player_line(%Player{} = p, tournament) do
    rating = Player.rating(p, tournament)

    [p.club, p.federation, rating && rating > 0 && to_string(rating)]
    |> Enum.reject(&(&1 in [nil, "", false]))
    |> Enum.join(" · ")
  end

  defp name_of(by_id, id), do: (by_id[id] && by_id[id].name) || gettext("(removed player)")

  defp engine_note(%Tournament{pairing_system: "round_robin"}),
    do:
      gettext(
        "A round robin's schedule is fixed, so it never reads any of this. The rules are kept in case the tournament is paired another way."
      )

  defp engine_note(%Tournament{pairing_system: "swiss", pairing_engine: "ainalrami"}), do: nil

  defp engine_note(%Tournament{pairing_system: "swiss"}),
    do:
      gettext(
        "This tournament pairs with JaVaFo: the rules are kept, but the wishes (if possible) are not applied until the engine is Ainalrami."
      )

  defp engine_note(_tournament),
    do: gettext("Keizer keeps the rules; it has no \"if possible\", so wishes are not applied.")

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        visible: filtered(assigns.players, assigns.query),
        fide_mode?: Compliance.fide_mode?(assigns.tournament),
        wish_count:
          Enum.count(assigns.pairs, & &1.soft) +
            Enum.count(assigns.field_rules ++ assigns.groups, & &1.soft)
      )

    ~H"""
    <Layouts.app
      publish_status={assigns[:publish_status]}
      update_notice={assigns[:update_notice]}
      flash={@flash}
      current_path={assigns[:current_path]}
      current_scope={@current_scope}
      tournament={@tournament}
      active="settings"
    >
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>

          <p class="subtitle" style="margin: 0">{gettext("Settings - Forbidden pairings")}</p>
        </div>
        <span class={["badge", @tournament.status == "setup" && "muted"]}>{@tournament.status}</span>
      </div>
      <.settings_subnav tournament={@tournament} active={:restrictions} />
      <.fide_exit_dialog
        id="fide-gate"
        step={@fide_gate && @fide_gate.step}
        reasons={(@fide_gate && @fide_gate.reasons) || []}
      />
      <div id="restrictions-fide-note" class={["prohib-banner", @departs? && "is-warm"]}>
        <%= cond do %>
          <% @departs? -> %>
            <strong>{gettext("Round 1 is paired.")}</strong> {gettext(
              "In FIDE mode, restrictions are announced before the first round (C.05 5.2). Adding, changing or removing one now asks twice and then takes the tournament out of FIDE mode, and the FIDE report says so. A player who joins later is covered by the rules as they stand: that is not a change."
            )}
          <% @fide_mode? -> %>
            <strong>{gettext("Set these before round 1 is paired.")}</strong> {gettext(
              "The FIDE rules (C.05 5.2) let you restrict the pairings - \"players of the same federation shall, if possible, not meet in the last rounds\" - as long as the players hear about it before the first round. After that, any change takes the tournament out of FIDE mode."
            )}
          <% true -> %>
            {gettext(
              "This tournament is not in FIDE mode: restrictions can be changed at any time. Changes made after round 1 are still listed in the TRF report."
            )}
        <% end %>
      </div>

      <p :if={engine_note(@tournament)} class="hint" id="restrictions-engine-note">
        {engine_note(@tournament)}
      </p>

      <div class="card" id="restrictions-effect">
        <h2>{gettext("Effect on the next round")}</h2>

        <%= if @check.round do %>
          <div class="prohib-stats">
            <span class="pe-stat">
              <span class="pe-stat-n" id="restrictions-forbidden-count">{@check.forbidden}</span> {ngettext(
                "game ruled out of %{possible} possible in round %{round}",
                "games ruled out of %{possible} possible in round %{round}",
                @check.forbidden,
                possible: @check.possible,
                round: @check.round
              )}
            </span>

            <span class="pe-stat">
              <span class="pe-stat-n">{@wish_count}</span> {ngettext(
                "wish (if possible)",
                "wishes (if possible)",
                @wish_count
              )}
            </span>
          </div>

          <p
            :if={@check.pairable == false}
            id="restrictions-unpairable"
            class="prohib-alert is-danger"
          >
            <strong>{gettext("Round %{round} cannot be paired.", round: @check.round)}</strong> {gettext(
              "With these restrictions and the games already played, there is no way to give every player an opponent they have not met and may meet. Remove or soften a restriction before pairing."
            )}
          </p>

          <p :if={@check.isolated != []} id="restrictions-isolated" class="prohib-alert is-warm">
            <strong>
              {ngettext(
                "One player has nobody left to play:",
                "%{count} players have nobody left to play:",
                length(@check.isolated)
              )}
            </strong>
            {Enum.map_join(@check.isolated, ", ", & &1.name)}
          </p>

          <p
            :if={
              @check.pairable != false and @check.possible > 0 and
                @check.forbidden * 2 > @check.possible
            }
            id="restrictions-dense"
            class="prohib-alert is-warm"
          >
            {gettext(
              "The restrictions rule out more than half of the games this field could have. The round may still pair, but the engine has little left to choose from: expect more floaters and colour compromises."
            )}
          </p>
        <% else %>
          <p class="hint" style="margin: 0">{gettext("Every round is paired.")}</p>
        <% end %>
      </div>

      <div class="card" id="restrictions-rules">
        <h2>{gettext("Rules")}</h2>

        <p class="hint" style="margin-top: 0">
          {gettext(
            "Keep players of the same club or federation apart without naming them: a rule follows the players as they are when a round is paired, so a late entrant or a corrected club is covered without touching it."
          )}
        </p>

        <ul :if={@field_rules != []} class="prohib-list" id="rule-list">
          <li :for={rule <- @field_rules} id={"rule-#{rule.id}"} class="prohib-row">
            <%= if @editing_rule == rule.id do %>
              <.rule_fields
                form={@edit_form}
                id={"edit-rule-form-#{rule.id}"}
                submit="update_rule"
                change="edit_rule_change"
                label={gettext("Save rule")}
                cancel="cancel_edit_rule"
                error={@rule_error}
              />
            <% else %>
              <div class="prohib-row-main">
                <span class="prohib-row-title">{rule_title(rule)}</span>
                <span class={["pe-tag", if(rule.soft, do: "pe-tag-muted", else: "pe-tag-ok")]}>
                  {if rule.soft, do: gettext("if possible"), else: gettext("rule")}
                </span>
                <span class="hint">{window_label(rule, @tournament)}</span>
              </div>
              <span class="prohib-row-effect">{effect_text(rule, @effects[rule.id])}</span>
              <span class="prohib-row-actions">
                <button
                  type="button"
                  class="pe-btn"
                  id={"edit-rule-#{rule.id}"}
                  phx-click="edit_rule"
                  phx-value-id={rule.id}
                >
                  {gettext("Edit")}
                </button>

                <button
                  type="button"
                  class="pe-btn danger-link"
                  id={"remove-rule-#{rule.id}"}
                  phx-click="remove_rule"
                  phx-value-id={rule.id}
                >
                  {gettext("Remove")}
                </button>
              </span>
            <% end %>
          </li>
        </ul>

        <p :if={@field_rules == []} class="hint">{gettext("No rules yet.")}</p>

        <h3 class="prohib-subhead">{gettext("Add a rule")}</h3>

        <.rule_fields
          form={@rule_form}
          id="add-rule-form"
          submit="add_rule"
          change="rule_change"
          label={gettext("Add rule")}
          error={@editing_rule == nil && @rule_error}
        />
      </div>

      <div class="card" id="restrictions-players">
        <h2>{gettext("Players who must not meet")}</h2>

        <p class="hint" style="margin-top: 0">
          {gettext(
            "Tick two or more players and keep them apart in one go: two make a forbidden pair, three or more a group whose members never meet each other."
          )}
        </p>

        <div class="prohib-picker" id="player-picker">
          <form id="player-search-form" phx-change="search" phx-submit="search">
            <input
              type="search"
              name="q"
              value={@query}
              id="player-search"
              placeholder={gettext("Search by name, club or federation")}
              aria-label={gettext("Search by name, club or federation")}
              autocomplete="off"
              phx-debounce="150"
            />
          </form>

          <div class="prohib-chips" id="selected-players">
            <span :if={@selected == []} class="hint">{gettext("No players ticked.")}</span>
            <button
              :for={id <- @selected}
              type="button"
              class="prohib-chip"
              phx-click="toggle_player"
              phx-value-id={id}
              title={gettext("Untick")}
            >
              {name_of(@players_by_id, id)} <span aria-hidden="true">×</span>
            </button>
          </div>

          <ul class="prohib-options" id="player-options">
            <li :for={p <- @visible}>
              <label class={["prohib-option", p.id in @selected && "is-on"]}>
                <input
                  type="checkbox"
                  id={"pick-#{p.id}"}
                  checked={p.id in @selected}
                  phx-click="toggle_player"
                  phx-value-id={p.id}
                /> <span class="prohib-option-name">{p.name}</span>
                <span class="prohib-option-meta">{player_line(p, @tournament)}</span>
              </label>
            </li>

            <li :if={@visible == []} class="hint" style="padding: 8px">
              {gettext("No player matches.")}
            </li>
          </ul>

          <form id="keep-apart-form" phx-submit="keep_apart" class="prohib-picker-actions">
            <label class="set-toggle" style="margin: 0">
              <input type="hidden" name="soft" value="false" />
              <input
                type="checkbox"
                name="soft"
                value="true"
                checked={@selection_soft}
                phx-click="selection_soft"
                phx-value-soft={to_string(!@selection_soft)}
              /> <span class="set-toggle-text">{gettext("Only if possible")}</span>
            </label>

            <button
              type="submit"
              id="keep-apart"
              class="pe-btn primary"
              disabled={length(@selected) < 2}
            >
              <%= cond do %>
                <% @editing_group -> %>
                  {gettext("Save group")}
                <% length(@selected) < 2 -> %>
                  {gettext("Keep apart")}
                <% true -> %>
                  {ngettext(
                    "Keep these %{count} apart",
                    "Keep these %{count} apart",
                    length(@selected)
                  )}
              <% end %>
            </button>

            <button
              :if={@selected != [] or @editing_group}
              type="button"
              class="pe-btn"
              phx-click="clear_selection"
            >
              {gettext("Clear")}
            </button>
          </form>

          <p :if={@error} class="error-note" id="picker-error">{@error}</p>
        </div>

        <ul :if={@groups != [] or @pairs != []} class="prohib-list" id="pair-list">
          <li
            :for={g <- @groups}
            id={"group-#{g.id}"}
            class={["prohib-row", @editing_group == g.id && "is-editing"]}
          >
            <div class="prohib-row-main">
              <span class="prohib-row-title">
                {Enum.map_join(g.player_ids, ", ", &name_of(@players_by_id, &1))}
              </span>

              <span class={["pe-tag", if(g.soft, do: "pe-tag-muted", else: "pe-tag-ok")]}>
                {if g.soft, do: gettext("if possible"), else: gettext("never")}
              </span>

              <span :if={g.from_round && g.from_round > 1} class="hint">
                {gettext("from round %{n}", n: g.from_round)}
              </span>
            </div>
            <span class="prohib-row-effect">{effect_text(g, @effects[g.id])}</span>
            <span class="prohib-row-actions">
              <button
                type="button"
                class="pe-btn"
                id={"edit-group-#{g.id}"}
                phx-click="edit_group"
                phx-value-id={g.id}
              >
                {gettext("Edit")}
              </button>

              <button
                type="button"
                class="pe-btn danger-link"
                id={"remove-group-#{g.id}"}
                phx-click="remove_rule"
                phx-value-id={g.id}
              >
                {gettext("Remove")}
              </button>
            </span>
          </li>

          <li :for={fp <- @pairs} id={"pair-#{fp.id}"} class="prohib-row">
            <div class="prohib-row-main">
              <span class="prohib-row-title">{fp.player_a.name} - {fp.player_b.name}</span>
              <span class={["pe-tag", if(fp.soft, do: "pe-tag-muted", else: "pe-tag-ok")]}>
                {if fp.soft, do: gettext("if possible"), else: gettext("never")}
              </span>

              <span :if={fp.from_round && fp.from_round > 1} class="hint">
                {gettext("from round %{n}", n: fp.from_round)}
              </span>
            </div>

            <span class="prohib-row-actions">
              <button
                type="button"
                class="pe-btn"
                id={"soft-pair-#{fp.id}"}
                phx-click="set_pair_soft"
                phx-value-id={fp.id}
                phx-value-soft={to_string(!fp.soft)}
              >
                {if fp.soft, do: gettext("Make it a rule"), else: gettext("Make it a wish")}
              </button>

              <button
                type="button"
                class="pe-btn danger-link"
                id={"remove-pair-#{fp.id}"}
                phx-click="remove_pair"
                phx-value-id={fp.id}
              >
                {gettext("Remove")}
              </button>
            </span>
          </li>
        </ul>

        <p :if={@groups == [] and @pairs == []} class="hint" style="margin-bottom: 0">
          {gettext("No players kept apart yet.")}
        </p>
      </div>

      <div class="card" id="restrictions-wishes">
        <h2>{gettext("How hard to try the wishes")}</h2>

        <p class="hint" style="margin-top: 0">
          {gettext(
            "A wish (if possible) is weighed against the pairing criteria and gives way when the rules leave no other legal round. A round in which a wish moves a board is not the round the FIDE rules pair, so in FIDE mode that round is recorded as leaving it."
          )}
        </p>

        <form id="soft-position-form" phx-submit="save_soft_position">
          <.setting_group>
            <.setting_field label={gettext("How hard to try")}>
              <select name="tournament[soft_position]" class="pe-select">
                <option
                  :for={p <- Tournament.soft_positions()}
                  value={p}
                  selected={p == @tournament.soft_position}
                >
                  {soft_position_label(p)}
                </option>
              </select>
            </.setting_field>
          </.setting_group>

          <div class="actions">
            <button type="submit" class="pe-btn primary">{gettext("Save")}</button>
            <span :if={@note} class="ok-note" style="align-self: center">{@note}</span>
          </div>
        </form>
      </div>
    </Layouts.app>
    """
  end

  defp soft_position_label("strong"), do: gettext("Strong - before the colour and float rules")
  defp soft_position_label("weak"), do: gettext("Weak - only as a tie-break")
  defp soft_position_label(other), do: other

  attr :form, :any, required: true
  attr :id, :string, required: true
  attr :submit, :string, required: true
  attr :change, :string, required: true
  attr :label, :string, required: true
  attr :cancel, :string, default: nil
  attr :error, :any, default: nil

  defp rule_fields(assigns) do
    ~H"""
    <.form for={@form} id={@id} phx-submit={@submit} phx-change={@change} class="prohib-rule-form">
      <div class="prohib-rule-grid">
        <.setting_field label={gettext("Keep apart")}>
          <select name="rule[kind]" class="pe-select">
            <option value="club" selected={@form[:kind].value == "club"}>
              {gettext("Players of the same club")}
            </option>

            <option value="federation" selected={@form[:kind].value == "federation"}>
              {gettext("Players of the same federation")}
            </option>
          </select>
        </.setting_field>

        <.setting_field
          label={gettext("Only these (optional)")}
          hint={gettext("Comma-separated. Empty means every club or federation.")}
        >
          <input
            type="text"
            name="rule[names]"
            value={@form[:names].value}
            placeholder={
              if @form[:kind].value == "federation",
                do: gettext("e.g. BEL, NED"),
                else: gettext("e.g. Chess Club A, Chess Club B")
            }
          />
        </.setting_field>

        <.setting_field label={gettext("Strength")}>
          <select name="rule[soft]" class="pe-select">
            <option value="false" selected={@form[:soft].value in ["false", false]}>
              {gettext("Never - a rule")}
            </option>

            <option value="true" selected={@form[:soft].value in ["true", true]}>
              {gettext("If possible - a wish")}
            </option>
          </select>
        </.setting_field>

        <.setting_field label={gettext("Rounds")}>
          <select name="rule[window]" class="pe-select">
            <option value="all" selected={@form[:window].value == "all"}>
              {gettext("Every round")}
            </option>

            <option value="first" selected={@form[:window].value == "first"}>
              {gettext("The first rounds")}
            </option>

            <option value="last" selected={@form[:window].value == "last"}>
              {gettext("The last rounds")}
            </option>

            <option value="range" selected={@form[:window].value == "range"}>
              {gettext("From round ... to round ...")}
            </option>
          </select>
        </.setting_field>

        <.setting_field
          :if={@form[:window].value in ["first", "last"]}
          label={gettext("How many rounds")}
        >
          <input
            type="number"
            min="1"
            step="1"
            name="rule[window_rounds]"
            value={@form[:window_rounds].value}
          />
        </.setting_field>

        <.setting_field :if={@form[:window].value == "range"} label={gettext("From round")}>
          <input
            type="number"
            min="1"
            step="1"
            name="rule[window_from]"
            value={@form[:window_from].value}
          />
        </.setting_field>

        <.setting_field :if={@form[:window].value == "range"} label={gettext("To round")}>
          <input
            type="number"
            min="1"
            step="1"
            name="rule[window_to]"
            value={@form[:window_to].value}
          />
        </.setting_field>
      </div>

      <p :if={@error} class="error-note">{@error}</p>

      <div class="actions">
        <button type="submit" class="pe-btn tonal" id={"#{@id}-submit"}>{@label}</button>
        <button :if={@cancel} type="button" class="pe-btn" phx-click={@cancel}>
          {gettext("Cancel")}
        </button>
      </div>
    </.form>
    """
  end
end
