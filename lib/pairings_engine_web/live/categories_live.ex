defmodule PairingsEngineWeb.CategoriesLive do
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport

  alias PairingsEngine.{Audit, CategoryRules, Tournaments}

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
       page_title: "#{tournament.name} · Categories",
       category_error: nil,
       assign_note: nil,
       toggle_error: nil,
       category_confirm: nil,
       # Which locked control (if any) the arbiter just clicked, for the
       # click-through "why is this locked" panel - same mechanism as
       # `SettingsOptionsLive`/`SettingsScoringLive`, see `locked_hint`
       # below.
       locked_hint: nil,
       # `:pair_by_category` once the "Unlock" button on that panel has been
       # used - deliberately per editing session, never persisted, and reset
       # the moment a toggle using it lands (see `toggle_pair_by_category/2`).
       unlocked_fields: MapSet.new()
     )
     |> assign_pair_by_category_lock()
     |> assign_rules_editor()}
  end

  # Same rationale as the other pairing-shape controls on the Options page
  # (pairing_system/rr_cycles/match format): once round 1 is paired, the
  # per-category split is baked into every board number and bye that
  # round produced, so changing it later would corrupt what's already on
  # the board - locked, not just discouraged.
  defp assign_pair_by_category_lock(socket) do
    tournament = socket.assigns.tournament

    locked? =
      :pair_by_category in Tournaments.locked_fields(tournament) and
        :pair_by_category not in socket.assigns.unlocked_fields

    socket
    |> assign(pair_by_category_locked?: locked?)
    # Whether turning CATEGORIES off would be refused. `categories_enabled`
    # is not itself locked, so the off-toggle works fine whenever
    # pair-by-category is already off - the refusal needs all three of:
    # categories on, pair-by-category on, and a round paired. In that state
    # the combined write carries `"pair_by_category" => "false"`, which
    # `ensure_unlocked/3` rejects unless `:pair_by_category` is unlocked, so
    # the switch could never be turned off again for the rest of the event
    # without going through the same "Unlock" as the toggle itself.
    #
    # It was not even silent about it: `error_text/1` has no
    # `:locked_after_pairing` clause, so the generic atom formatter rendered
    # the bare string "locked after pairing" - naming a setting the arbiter
    # had not touched.
    |> assign(categories_off_locked?: locked? and tournament.pair_by_category)
  end

  # `rules_draft` mirrors the "one editable row per category" table below,
  # index-aligned with `tournament.categories` - the same "flat list, index
  # is identity" shape `SettingsDatesLive`'s `round_dates` form state uses,
  # chosen for the same reason: a category NAME is free text and cannot
  # safely become an HTML form field name, so the form addresses rows by
  # position (`rule[0][rating_from]`, `rule[1][rating_from]`, ...) and this
  # list is what the phx-change handler updates and the template reads back
  # from - unsaved keystrokes included, which is what lets the live
  # birth-year hint and the live summary track what the arbiter is
  # actually typing rather than only what was last saved.
  #
  # `tournament_year` drives the age conditions' birth-year hints
  # (`CategoryRules.tournament_year/1` - see its own doc for which year
  # that is); reassigned alongside `rules_draft` any time the tournament
  # changes, since a round-date edit elsewhere can change it.
  defp assign_rules_editor(socket) do
    tournament = socket.assigns.tournament

    assign(socket,
      rules_draft: build_rules_draft(tournament),
      tournament_year: CategoryRules.tournament_year(tournament)
    )
  end

  defp build_rules_draft(tournament) do
    Enum.map(tournament.categories, fn name ->
      rule = Map.get(tournament.category_rules, name) || %{}
      prize = Map.get(tournament.category_prizes, name)

      %{
        "rating_from" => draft_string(Map.get(rule, "rating_from")),
        "rating_below" => draft_string(Map.get(rule, "rating_below")),
        "age_from" => draft_string(Map.get(rule, "age_from")),
        "age_below" => draft_string(Map.get(rule, "age_below")),
        "women" => if(Map.get(rule, "women") == true, do: "true", else: "false"),
        "prize" => draft_string(prize)
      }
    end)
  end

  defp draft_string(nil), do: ""
  defp draft_string(n) when is_integer(n), do: Integer.to_string(n)
  defp draft_string(n), do: to_string(n)

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
         |> assign(tournament: tournament)
         |> assign_pair_by_category_lock()
         |> assign_rules_editor()}
    end
  end

  ## ---------- On/off switches - instant, no separate "Save" step ----------

  # Guarded on the one field this page's `locked_overlay/1` sends - see the
  # same guard in `SettingsOptionsLive` for why an unguarded
  # `String.to_existing_atom/1` on a param is a self-inflicted crash.
  @locked_fields ~w(pair_by_category)

  def handle_event("locked_hint", %{"field" => field}, socket)
      when field in @locked_fields do
    {:noreply, assign(socket, locked_hint: String.to_existing_atom(field))}
  end

  def handle_event("locked_hint", _params, socket), do: {:noreply, socket}

  # Same allowlist, same reasoning as `SettingsOptionsLive`'s "unlock_field"
  # clause: this is a UI convenience, not the security boundary -
  # `Tournaments.ensure_unlocked/3` refuses the actual write regardless of
  # what reaches it here.
  def handle_event("unlock_field", %{"field" => field}, socket)
      when field in @locked_fields do
    field = String.to_existing_atom(field)

    {:noreply,
     socket
     |> assign(locked_hint: nil)
     |> update(:unlocked_fields, &MapSet.put(&1, field))
     |> assign_pair_by_category_lock()}
  end

  def handle_event("unlock_field", _params, socket), do: {:noreply, socket}

  # Turning categories off also forces `pair_by_category` off in the same
  # write: `Tournament.changeset/2`'s own
  # `validate_pair_by_category_requires_categories/1` would otherwise
  # reject this exact toggle whenever pair-by-category was already on,
  # since as far as the changeset can tell both fields would be changing
  # at once and pair_by_category can't outlive the categories switch it
  # depends on.
  def handle_event("toggle_categories_enabled", _params, socket) do
    tournament = socket.assigns.tournament
    enabled? = !tournament.categories_enabled

    params =
      cond do
        enabled? ->
          %{"categories_enabled" => "true"}

        # Only send the locked field when there is something to change. With
        # pair-by-category already off, the key added nothing and turned an
        # ordinary toggle into a write that `ensure_unlocked/3` refuses.
        tournament.pair_by_category ->
          %{"categories_enabled" => "false", "pair_by_category" => "false"}

        true ->
          %{"categories_enabled" => "false"}
      end

    # This toggle carries `pair_by_category => false` exactly when
    # `categories_off_locked?` would otherwise refuse it - unlocking
    # `pair_by_category` (the same "Unlock" the toggle button below offers)
    # covers this write too, since it's the same underlying change.
    unlock_fields =
      if :pair_by_category in socket.assigns.unlocked_fields, do: [:pair_by_category], else: []

    case Tournaments.update_tournament(tournament, params, unlock: unlock_fields) do
      {:ok, updated} ->
        Audit.log(updated.id, socket.assigns.current_scope, "categories.toggled", %{
          enabled: enabled?
        })

        log_unlocked_field_changes(socket, tournament, updated, unlock_fields)
        log_compliance_departures(socket, tournament, updated)

        {:noreply,
         socket
         |> assign(tournament: updated, toggle_error: nil, unlocked_fields: MapSet.new())
         |> assign_pair_by_category_lock()}

      {:error, reason} ->
        {:noreply, assign(socket, toggle_error: error_text(reason))}
    end
  end

  def handle_event("toggle_pair_by_category", _params, socket) do
    if socket.assigns.pair_by_category_locked? do
      {:noreply, socket}
    else
      tournament = socket.assigns.tournament
      enabled? = !tournament.pair_by_category

      unlock_fields =
        if :pair_by_category in socket.assigns.unlocked_fields, do: [:pair_by_category], else: []

      case Tournaments.update_tournament(
             tournament,
             %{"pair_by_category" => to_string(enabled?)},
             unlock: unlock_fields
           ) do
        {:ok, updated} ->
          Audit.log(updated.id, socket.assigns.current_scope, "pair_by_category.toggled", %{
            enabled: enabled?
          })

          log_unlocked_field_changes(socket, tournament, updated, unlock_fields)
          log_compliance_departures(socket, tournament, updated)

          {:noreply,
           socket
           |> assign(tournament: updated, toggle_error: nil, unlocked_fields: MapSet.new())
           |> assign_pair_by_category_lock()}

        {:error, changeset} ->
          {:noreply, assign(socket, toggle_error: error_text(changeset))}
      end
    end
  end

  ## ---------- Categories (SWAR CATEGORIES) - any authorized user ----------

  @impl true
  def handle_event("add_category", %{"name" => name} = params, socket) do
    trimmed = String.trim(name)
    categories = socket.assigns.tournament.categories || []

    cond do
      trimmed == "" ->
        {:noreply, assign(socket, category_error: gettext("Enter a category name"))}

      trimmed in categories ->
        {:noreply, assign(socket, category_error: gettext("That category already exists"))}

      true ->
        case parse_rule_fields(params) do
          {:ok, rule} ->
            category_rules =
              if CategoryRules.rule_owned?(rule) do
                Map.put(socket.assigns.tournament.category_rules, trimmed, rule)
              else
                socket.assigns.tournament.category_rules
              end

            case Tournaments.update_tournament(socket.assigns.tournament, %{
                   "categories" => categories ++ [trimmed],
                   "category_rules" => category_rules
                 }) do
              {:ok, tournament} ->
                Audit.log(tournament.id, socket.assigns.current_scope, "category.created", %{
                  name: trimmed,
                  rule: Map.get(category_rules, trimmed)
                })

                {:noreply,
                 socket
                 |> assign(tournament: tournament, category_error: nil)
                 |> assign_rules_editor()}

              {:error, changeset} ->
                {:noreply, assign(socket, category_error: error_text(changeset))}
            end

          {:error, message} ->
            {:noreply, assign(socket, category_error: message)}
        end
    end
  end

  # Deliberately does not touch a single player row.
  #
  # A removed category left on a player is inert everywhere it could matter:
  # `PairingsEngine.Categories.pairing_category/2` only ever returns a name
  # the tournament still lists, so an unlisted one cannot decide a pairing
  # pool, and `listed_categories/2` filters it out of every display and
  # printed table. So stripping it from the roster would buy no correctness
  # and cost the assignments outright - a settings edit that silently
  # rewrote several hundred player rows, with nothing to undo it.
  #
  # Leaving them means re-adding the name brings the assignments back, which
  # is the closest thing this page has to an undo for a mis-click. The rule
  # and the prize count DO come off with the category, same as they always
  # have for the rule - a category that no longer exists having an orphaned
  # rule or prize count sitting in either map would be surprising the first
  # time someone re-added a DIFFERENT category of the same name.
  def handle_event("remove_category", %{"name" => name}, socket) do
    categories = List.delete(socket.assigns.tournament.categories || [], name)
    category_rules = Map.delete(socket.assigns.tournament.category_rules, name)
    category_prizes = Map.delete(socket.assigns.tournament.category_prizes, name)

    case Tournaments.update_tournament(socket.assigns.tournament, %{
           "categories" => categories,
           "category_rules" => category_rules,
           "category_prizes" => category_prizes
         }) do
      {:ok, tournament} ->
        Audit.log(tournament.id, socket.assigns.current_scope, "category.removed", %{name: name})

        {:noreply,
         socket
         |> assign(tournament: tournament, category_error: nil, assign_note: nil)
         |> assign_rules_editor()}

      {:error, reason} ->
        {:noreply, assign(socket, category_error: error_text(reason))}
    end
  end

  # Tracks what the arbiter is typing into the rules table WITHOUT saving -
  # the live birth-year hint and the live summary both read `rules_draft`,
  # not `tournament.category_rules`, so they follow every keystroke. Only
  # the rows Phoenix actually reports (`params["rule"]`, keyed "0", "1", ...
  # by position) are merged in; a row nothing changed keeps its last known
  # draft value rather than being reset to blank.
  def handle_event("rules_change", %{"rule" => rule_params}, socket) do
    {:noreply,
     assign(socket, rules_draft: merge_rules_draft(socket.assigns.rules_draft, rule_params))}
  end

  def handle_event("rules_change", _params, socket), do: {:noreply, socket}

  # The single save for every category's rule AND prize count at once - one
  # table, one submit, same "whole list travels together" shape
  # `SettingsDatesLive`'s round-dates form already uses. `build_rules_and_prizes/2`
  # validates every row before anything is written, so a typo in row 3
  # cannot half-save rows 1-2.
  def handle_event("save_rules", %{"rule" => rule_params}, socket) do
    tournament = socket.assigns.tournament
    draft = merge_rules_draft(socket.assigns.rules_draft, rule_params)

    case build_rules_and_prizes(tournament.categories, draft) do
      {:ok, category_rules, category_prizes} ->
        case Tournaments.update_tournament(tournament, %{
               "category_rules" => category_rules,
               "category_prizes" => category_prizes
             }) do
          {:ok, updated} ->
            Audit.log(updated.id, socket.assigns.current_scope, "category.rules_updated", %{})

            {:noreply,
             socket
             |> assign(tournament: updated, category_error: nil, assign_note: nil)
             |> assign_rules_editor()}

          {:error, reason} ->
            {:noreply, assign(socket, category_error: error_text(reason), rules_draft: draft)}
        end

      {:error, message} ->
        {:noreply, assign(socket, category_error: message, rules_draft: draft)}
    end
  end

  # "Assign categories" - SWAR-style bulk rule application, same pattern as
  # the extra-points bands button: applies `tournament.category_rules` to
  # every player, replacing the categories the rules own and leaving
  # hand-set ones alone (see `Tournaments.auto_assign_categories/1` for why
  # that is now narrower than it used to be). Step 1 is a dry run: compute the same
  # decisions `auto_assign_categories/1` would make (via
  # `preview_auto_assign_categories/1`, so preview and apply can never
  # disagree) without writing anything, and show the arbiter a before/after
  # diff to confirm. Nothing is persisted until `apply_category_confirm`.
  def handle_event("assign_categories", _params, socket) do
    preview = Tournaments.preview_auto_assign_categories(socket.assigns.tournament)

    changes =
      Enum.filter(preview, fn c ->
        c.from != c.to or c.from_category != c.to_category
      end)

    if changes == [] do
      {:noreply,
       assign(socket,
         category_confirm: nil,
         category_error: nil,
         assign_note: gettext("No changes needed - every player already matches the rules.")
       )}
    else
      {:noreply,
       assign(socket,
         category_confirm: %{changes: changes, total: length(preview)},
         category_error: nil,
         assign_note: nil
       )}
    end
  end

  def handle_event("cancel_category_confirm", _params, socket) do
    {:noreply, assign(socket, category_confirm: nil)}
  end

  # The explicit second click. Re-runs the real write path (not just the
  # staged preview) so the write always reflects the current DB state at
  # confirm time - same "read again at apply time" caution as
  # `PairingsLive`'s own `apply_confirm/2`.
  def handle_event("apply_category_confirm", _params, socket) do
    case Tournaments.auto_assign_categories(socket.assigns.tournament) do
      {:ok, %{matched: matched, total: total}} ->
        Audit.log(
          socket.assigns.tournament.id,
          socket.assigns.current_scope,
          "category.auto_assigned",
          %{matched: matched, total: total}
        )

        {:noreply,
         assign(socket,
           category_confirm: nil,
           assign_note:
             gettext("Assigned %{matched} of %{total} players.", matched: matched, total: total)
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           category_confirm: nil,
           assign_note: nil,
           category_error: error_text(reason)
         )}
    end
  end

  defp merge_rules_draft(draft, rule_params) do
    draft
    |> Enum.with_index()
    |> Enum.map(fn {row, index} ->
      case Map.get(rule_params, Integer.to_string(index)) do
        nil -> row
        submitted -> Map.merge(row, submitted)
      end
    end)
  end

  defp build_rules_and_prizes(categories, draft) do
    categories
    |> Enum.zip(draft)
    |> Enum.reduce_while({:ok, %{}, %{}}, fn {name, row}, {:ok, rules, prizes} ->
      with {:ok, rule} <- parse_rule_fields(row),
           {:ok, prize} <- parse_prize_field(row) do
        rules = if CategoryRules.rule_owned?(rule), do: Map.put(rules, name, rule), else: rules

        prizes =
          if is_integer(prize) and prize > 0, do: Map.put(prizes, name, prize), else: prizes

        {:cont, {:ok, rules, prizes}}
      else
        {:error, message} -> {:halt, {:error, "#{name}: #{message}"}}
      end
    end)
  end

  ## ---------- Condition parsing (shared by the add-form and the table) ----------

  # Both the "New category" form's params and one row of `rules_draft` are
  # flat string-keyed maps with the same five keys, so one parser serves
  # both call sites.
  defp parse_rule_fields(fields) do
    with {:ok, rule} <- put_int_field(%{}, fields, "rating_from"),
         {:ok, rule} <- put_int_field(rule, fields, "rating_below"),
         {:ok, rule} <- put_int_field(rule, fields, "age_from"),
         {:ok, rule} <- put_int_field(rule, fields, "age_below") do
      {:ok, maybe_put_women(rule, fields)}
    end
  end

  defp put_int_field(rule, fields, key) do
    case String.trim(to_string(Map.get(fields, key, ""))) do
      "" ->
        {:ok, rule}

      value ->
        case Integer.parse(value) do
          {n, ""} when n > 0 ->
            {:ok, Map.put(rule, key, n)}

          _ ->
            {:error,
             gettext("Enter a positive whole number for %{field}", field: field_label(key))}
        end
    end
  end

  defp field_label("rating_from"), do: gettext("rating from")
  defp field_label("rating_below"), do: gettext("rating below")
  defp field_label("age_from"), do: gettext("age from")
  defp field_label("age_below"), do: gettext("under age")

  defp maybe_put_women(rule, fields) do
    if truthy?(Map.get(fields, "women")), do: Map.put(rule, "women", true), else: rule
  end

  defp truthy?(value), do: value in ["true", "on", true]

  defp parse_prize_field(fields) do
    case String.trim(to_string(Map.get(fields, "prize", ""))) do
      "" ->
        {:ok, nil}

      value ->
        case Integer.parse(value) do
          {n, ""} when n >= 0 -> {:ok, n}
          _ -> {:error, gettext("Enter a whole number for the prize count")}
        end
    end
  end

  ## ---------- Live summary + birth-year hints ----------

  # Best-effort parse of one draft row for the LIVE summary/hint only - a
  # field that doesn't parse yet (mid-keystroke, or genuinely invalid) is
  # simply treated as unset here rather than surfaced as an error; real
  # validation is `parse_rule_fields/1`'s job, at save time.
  defp draft_rule(row) do
    case parse_rule_fields(row) do
      {:ok, rule} -> rule
      {:error, _message} -> %{}
    end
  end

  defp rule_summary(rule) do
    if CategoryRules.rule_owned?(rule) do
      [rating_summary(rule), age_summary(rule), women_summary(rule)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")
    else
      gettext("Hand-assigned - no rule")
    end
  end

  defp rating_summary(%{"rating_from" => f, "rating_below" => b}),
    do: gettext("rating %{from}-%{to}", from: f, to: b - 1)

  defp rating_summary(%{"rating_from" => f}), do: gettext("rating %{from}+", from: f)
  defp rating_summary(%{"rating_below" => b}), do: gettext("rating below %{value}", value: b)
  defp rating_summary(_rule), do: nil

  defp age_summary(%{"age_from" => f, "age_below" => b}),
    do: gettext("age %{from}-%{to}", from: f, to: b - 1)

  defp age_summary(%{"age_from" => f}), do: gettext("age %{from}+", from: f)
  defp age_summary(%{"age_below" => b}), do: gettext("under age %{value}", value: b)
  defp age_summary(_rule), do: nil

  defp women_summary(%{"women" => true}), do: gettext("women")
  defp women_summary(_rule), do: nil

  # The live "born YYYY or later/earlier" hint shown next to each age
  # input - `nil` (rendered as nothing) while the field is blank or not yet
  # a valid positive integer, same tolerance `draft_rule/1` has for a
  # mid-keystroke value.
  defp age_below_hint(row, year) do
    case parse_positive(Map.get(row, "age_below", "")) do
      {:ok, v} ->
        gettext("under %{age} = born %{year} or later",
          age: v,
          year: CategoryRules.birth_year_on_or_after(year, v)
        )

      :error ->
        nil
    end
  end

  defp age_from_hint(row, year) do
    case parse_positive(Map.get(row, "age_from", "")) do
      {:ok, v} ->
        gettext("%{age}+ = born %{year} or earlier",
          age: v,
          year: CategoryRules.birth_year_on_or_before(year, v)
        )

      :error ->
        nil
    end
  end

  defp parse_positive(value) do
    case Integer.parse(String.trim(to_string(value))) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
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
      active="categories"
    >
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">{gettext("Categories")}</p>
        </div>
      </div>

      <.settings_subnav tournament={@tournament} active={:categories} />

      <.compliance_notice tournament={@tournament} />

      <div class="card">
        <h2>{gettext("Categories")}</h2>

        <p class="hint" style="margin-top: 0">
          {gettext(
            "Tournament-defined groups (SWAR CATEGORIES) - e.g. age or rating brackets - players can be assigned to. Off by default; turn on to start adding them below."
          )}
        </p>

        <div class="set-field solo">
          <span class="set-label">{gettext("Status")}</span>
          <div class="actions" style="margin-top: 6px; align-items: center; gap: 10px">
            <span>{if @tournament.categories_enabled, do: "On", else: "Off"}</span>
            <button
              type="button"
              class="pe-btn"
              phx-click="toggle_categories_enabled"
              disabled={@categories_off_locked?}
            >
              {if @tournament.categories_enabled, do: "Turn off", else: "Turn on"}
            </button>
          </div>
          <%!-- Turning categories off would also have to turn pair-by-category
                off, and that IS locked once a round is paired. Said here, next
                to the disabled control, rather than left to a refusal that
                named a setting the arbiter never touched. --%>
          <p :if={@categories_off_locked?} class="hint" style="margin: 6px 0 0">
            {gettext(
              "Locked - categories cannot be turned off while pairing by category, and that cannot change after round 1 has been paired."
            )}
          </p>
        </div>

        <div
          :if={@tournament.categories_enabled}
          class="set-field solo"
          style="margin-top: 10px"
        >
          <span class="set-label">{gettext("Pair each category independently (beta)")}</span>
          <p class="hint" style="margin: 2px 0 6px">
            {gettext(
              "Swiss only - each category gets its own independent pairings and byes within one combined round."
            )}
          </p>
          <div class="actions" style="align-items: center; gap: 10px">
            <span>{if @tournament.pair_by_category, do: "On", else: "Off"}</span>
            <div class="locked-wrap locked-wrap-inline">
              <button
                type="button"
                class="pe-btn"
                phx-click="toggle_pair_by_category"
                disabled={@pair_by_category_locked?}
              >
                {if @tournament.pair_by_category, do: "Turn off", else: "Turn on"}
              </button>
              <.locked_overlay field={:pair_by_category} locked?={@pair_by_category_locked?} />
            </div>
          </div>
          <.locked_hint_message
            field={:pair_by_category}
            locked_hint={@locked_hint}
            warning={pair_by_category_warning()}
          />
        </div>

        <p :if={@toggle_error} class="error-note" style="margin-top: 10px">{@toggle_error}</p>
      </div>

      <div :if={@tournament.categories_enabled}>
        <div class="card">
          <h2>{gettext("Category list")}</h2>
          <p class="hint" style="margin-top: 0">
            <.rich_text text={
              gettext(
                ~s(Players are assigned a category on the %[players] page. Set any combination of the conditions below and a category can be filled in for every player automatically, further down. Leave every condition blank to keep assigning it by hand.)
              )
            }>
              <:part name="players">
                <.link navigate={~p"/t/#{@tournament.id}/players"}>{gettext("Players")}</.link>
              </:part>
            </.rich_text>
          </p>
          <p class="hint">
            {gettext(
              "An unrated player satisfies a \"rating below\" condition (0 is under any ceiling) but never a \"rating from\" one."
            )}
          </p>

          <form id="add-category-form" phx-submit="add_category">
            <.setting_group>
              <.setting_field label={gettext("New category name")}>
                <input type="text" name="name" value="" placeholder={gettext("e.g. U1800 or 45+")} />
              </.setting_field>
              <.setting_field label={gettext("Rating from")}>
                <input type="number" name="rating_from" value="" min="1" />
              </.setting_field>
              <.setting_field label={gettext("Rating below")}>
                <input type="number" name="rating_below" value="" min="1" />
              </.setting_field>
              <.setting_field label={gettext("Age from")}>
                <input type="number" name="age_from" value="" min="1" />
              </.setting_field>
              <.setting_field label={gettext("Under age")}>
                <input type="number" name="age_below" value="" min="1" />
              </.setting_field>
            </.setting_group>
            <label class="set-toggle" style="margin-top: 6px">
              <input type="hidden" name="women" value="false" />
              <input type="checkbox" name="women" value="true" />
              <span class="set-toggle-text">{gettext("Women only")}</span>
            </label>
            <p :if={@category_error} class="error-note">{@category_error}</p>
            <div class="actions">
              <button type="submit" class="pe-btn primary">Add</button>
            </div>
          </form>

          <div :if={@tournament.categories != []} class="card-table-wrap" style="margin-top: 16px">
            <form id="rules-form" phx-change="rules_change" phx-submit="save_rules">
              <table class="pe-table">
                <thead>
                  <tr>
                    <th>{gettext("Category")}</th>
                    <th class="num">{gettext("Rating from")}</th>
                    <th class="num">{gettext("Rating below")}</th>
                    <th class="num">{gettext("Age from")}</th>
                    <th class="num">{gettext("Under age")}</th>
                    <th>{gettext("Women")}</th>
                    <th class="num">{gettext("Prizes")}</th>
                    <th>{gettext("Summary")}</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={
                    {{c, row}, idx} <- Enum.with_index(Enum.zip(@tournament.categories, @rules_draft))
                  }>
                    <td>{c}</td>
                    <td class="num">
                      <input
                        type="number"
                        name={"rule[#{idx}][rating_from]"}
                        value={row["rating_from"]}
                        min="1"
                        style="width: 80px"
                      />
                    </td>
                    <td class="num">
                      <input
                        type="number"
                        name={"rule[#{idx}][rating_below]"}
                        value={row["rating_below"]}
                        min="1"
                        style="width: 80px"
                      />
                    </td>
                    <td class="num">
                      <input
                        type="number"
                        name={"rule[#{idx}][age_from]"}
                        value={row["age_from"]}
                        min="1"
                        style="width: 70px"
                      />
                      <div :if={age_from_hint(row, @tournament_year)} class="hint" style="margin: 0">
                        {age_from_hint(row, @tournament_year)}
                      </div>
                    </td>
                    <td class="num">
                      <input
                        type="number"
                        name={"rule[#{idx}][age_below]"}
                        value={row["age_below"]}
                        min="1"
                        style="width: 70px"
                      />
                      <div :if={age_below_hint(row, @tournament_year)} class="hint" style="margin: 0">
                        {age_below_hint(row, @tournament_year)}
                      </div>
                    </td>
                    <td>
                      <input type="hidden" name={"rule[#{idx}][women]"} value="false" />
                      <input
                        type="checkbox"
                        name={"rule[#{idx}][women]"}
                        value="true"
                        checked={row["women"] == "true"}
                      />
                    </td>
                    <td class="num">
                      <input
                        type="number"
                        name={"rule[#{idx}][prize]"}
                        value={row["prize"]}
                        min="0"
                        style="width: 60px"
                      />
                    </td>
                    <td>{rule_summary(draft_rule(row))}</td>
                    <td style="text-align: right">
                      <button
                        type="button"
                        class="pe-btn danger-link"
                        phx-click="remove_category"
                        phx-value-name={c}
                      >
                        {gettext("Remove")}
                      </button>
                    </td>
                  </tr>
                </tbody>
              </table>
              <div class="actions" style="margin-top: 10px">
                <button type="submit" class="pe-btn primary">{gettext("Save rules")}</button>
              </div>
            </form>
          </div>

          <p :if={@tournament.categories == []} class="hint" style="margin-bottom: 0">
            {gettext("No categories yet.")}
          </p>

          <div
            :if={@tournament.categories != [] and @tournament.category_rules != %{}}
            class="actions"
            style="margin-top: 16px"
          >
            <button type="button" class="pe-btn primary" phx-click="assign_categories">
              {gettext("Assign categories")}
            </button>
            <span :if={@assign_note} class="ok-note" style="align-self: center">{@assign_note}</span>
          </div>
          <p :if={@category_error} class="error-note" style="margin-top: 10px">
            {@category_error}
          </p>
        </div>
      </div>

      <div
        :if={@category_confirm}
        class="pe-modal"
        phx-window-keydown="cancel_category_confirm"
        phx-key="escape"
      >
        <div class="pe-modal-card pe-modal-wide" phx-click-away="cancel_category_confirm">
          <div class="pe-modal-head">
            <h2>{gettext("Assign categories?")}</h2>
            <p>
              {gettext(
                "Applying the threshold rules would change the categories of %{changed} of %{total} players. Categories with no rule are left alone. Players with no change are omitted below.",
                changed: length(@category_confirm.changes),
                total: @category_confirm.total
              )}
            </p>
          </div>
          <div class="pe-modal-body">
            <div class="card-table-wrap">
              <table class="pe-table">
                <thead>
                  <tr>
                    <th>{gettext("Player")}</th>
                    <th>{gettext("From")}</th>
                    <th>To</th>
                    <th>{gettext("Pairing pool")}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={change <- @category_confirm.changes}>
                    <td>{change.player.name}</td>
                    <td>{empty_dash(Enum.join(change.from, ", "))}</td>
                    <td>{empty_dash(Enum.join(change.to, ", "))}</td>
                    <%!-- The pairing pool is single-valued and changes on its
                          own rules, so it gets its own column rather than
                          being folded into the set it is drawn from. --%>
                    <td>
                      {empty_dash(change.from_category)} → {empty_dash(change.to_category)}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
          <div class="pe-modal-foot">
            <button type="button" class="pe-btn" phx-click="cancel_category_confirm">
              {gettext("Cancel")}
            </button>
            <button
              type="button"
              class="pe-btn primary pe-modal-go"
              phx-click="apply_category_confirm"
            >
              {gettext("Assign categories")}
            </button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp pair_by_category_warning,
    do:
      gettext(
        "The per-category split is baked into every board number and bye the round already produced. Changing this now doesn't renumber what's already on the board - it changes how the NEXT round is built, so boards from before and after the change follow different numbering rules within the same tournament."
      )

  defp empty_dash(""), do: "-"
  defp empty_dash(value), do: value
end
