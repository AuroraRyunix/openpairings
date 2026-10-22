defmodule PairingsEngineWeb.SettingsSupport do
  @moduledoc """
  Shared helpers and the sub-nav component for the split Settings pages
  (`SettingsTournamentLive`, `SettingsOptionsLive`, `SettingsDatesLive`,
  `SettingsFideLive`, `ExtraPointsLive`) and `CategoriesLive`.

  The old monolithic `SettingsLive` was one ~1900-line page; it's now six
  focused pages sharing:

    * `settings_page/1` - the frame each page sits in: heading, the rail
      of pages (`settings_subnav/1`), and the "Show advanced settings"
      switch with `attach_advanced/1` and `changed_count/2` behind it.
      Laid out like the account page, which got there first.
    * `save_status/1` - the tick-and-note answer under a Save button.
    * the dirty/stale tracker mechanism - each page whose form renders its
      inputs' `value` straight from `@tournament` must not blindly reload
      `@tournament` on every PubSub broadcast (that would reset text the user
      is mid-typing). `attach_dirty_tracker/1` flips `dirty` the moment any
      event fires; `handle_stale_check/1` only flags the page `stale` when a
      freshly-loaded row actually differs from what's assigned.
    * `log_settings_change/3` / `tournament_diff/2` - the before/after audit
      diff written on every settings save.
    * `error_text/1` - changeset error formatting.
    * the settings layout primitives - `setting_group/1`, `setting_field/1`,
      `setting_toggle/1` - plus the `locked_overlay/1` / `locked_hint_message/1`
      pair they build on. See the `.set-*` block in `app.css` for the layout
      model and why settings doesn't share `.form-grid` with the other pages.
  """
  use PairingsEngineWeb, :html

  require Logger

  import Phoenix.LiveView, only: [attach_hook: 4]

  alias PairingsEngine.{Audit, Compliance, Tournaments}
  alias PairingsEngine.Tournaments.Tournament

  # Tournament fields excluded from the settings audit diff - derived,
  # internal or noisy (binary logo blob, PubSub-recomputed status/flags,
  # timestamps, ownership). Everything else is diffed field-by-field.
  #
  # `fide_compliance_lost_round` is here for the same reason
  # `manual_ranking_stale` is: it is not a setting anybody submitted, it is
  # written by `Tournaments` in the same changeset as the save that caused
  # it, and it has its own audit action (`log_compliance_departures/3`)
  # saying which setting did it. In the bulk diff it would read as an
  # eleventh changed field with no cause attached.
  @settings_diff_ignore ~w(id status public_slug public_slug_minted_at public_slug_server
    public_slug_published_at deleted_at
    manual_ranking_stale fide_compliance_lost_round
    logo_data logo_content_type inserted_at updated_at user_id
    pairing_numbers_origin tpn_order_accepted late_entry_notice_dismissed
    registrations_checked_at)a

  @doc """
  The frame every tournament Settings page sits in - the account page's
  layout (`UserLive.Settings`) with the tournament's pages in its rail:
  the heading, a rail of the pages beside the cards (a row of chips on a
  phone), and, on a page that has any, the "Show advanced settings"
  switch above them.

  ## Common and advanced

  Each page shows by default what nearly every tournament sets, and keeps
  the rest behind the switch. An advanced setting is marked with the
  `tset-adv` class and stays in the page and in the form - hidden by CSS,
  not left out of the render - so a save sends exactly the fields it sent
  before the switch existed, and nothing about what a page saves depends on
  whether somebody was looking at all of it.

  Hidden is never silent: `advanced` carries how many of the page's
  advanced settings differ from their defaults, and while the switch is off
  that number is a link that turns it on. See `changed_count/2`.

  The switch itself belongs to the account (`users.settings_advanced`) and
  is flipped by the `"settings_advanced"` event `attach_advanced/1` handles,
  so it is the same on every page and every device the arbiter signs in on.

  `advanced` is nil on a page with nothing advanced in it, and the switch
  is not drawn there.
  """
  attr :tournament, :map, required: true
  attr :active, :any, required: true
  attr :current_scope, :any, default: nil
  attr :subtitle, :string, required: true
  attr :show_status, :boolean, default: true
  attr :advanced, :map, default: nil
  attr :id, :string, default: "settings-page"
  slot :subtitle_extra
  slot :inner_block, required: true

  def settings_page(assigns) do
    ~H"""
    <div class="tset-page" id={@id}>
      <div class="page-header tset-header">
        <div>
          <h1>{@tournament.name}</h1>

          <p class="subtitle" style="margin: 0">{@subtitle} {render_slot(@subtitle_extra)}</p>
        </div>

        <span
          :if={@show_status}
          class={["badge", @tournament.status == "setup" && "muted"]}
        >
          {@tournament.status}
        </span>
      </div>

      <div class="tset-layout">
        <.settings_subnav tournament={@tournament} active={@active} current_scope={@current_scope} />
        <div class={["tset-main", @advanced && @advanced.on? && "show-advanced"]} id="settings-main">
          <div :if={@advanced} class="tset-bar" id="settings-advanced-bar">
            <button
              type="button"
              id="settings-advanced-toggle"
              class="tset-switch"
              role="switch"
              aria-checked={to_string(@advanced.on?)}
              phx-click="settings_advanced"
              phx-value-on={to_string(!@advanced.on?)}
            >
              <span class="tset-switch-track" aria-hidden="true">
                <span class="tset-switch-thumb"></span>
              </span>
              {gettext("Show advanced settings")}
            </button>

            <button
              :if={!@advanced.on? and @advanced.changed > 0}
              type="button"
              id="settings-advanced-changed"
              class="tset-changed"
              phx-click="settings_advanced"
              phx-value-on="true"
            >
              <.icon name="hero-adjustments-horizontal-micro" class="size-4" /> {ngettext(
                "1 advanced setting is not at its default - show it",
                "%{count} advanced settings are not at their defaults - show them",
                @advanced.changed
              )}
            </button>
          </div>
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  @doc """
  The rail of Settings pages, grouped the way an arbiter meets them:
  setting the tournament up, putting it in front of people, reporting it.
  `active` is one of `:tournament`, `:options`, `:restrictions`, `:scoring`,
  `:group`, `:dates`, `:rooms`, `:categories`, `:extra_points`, `:results`, `:boards`, `:fide`,
  `:norms`, `:export`, `:about`. A plugin's page is `"plugin:" <> id`
  (`PairingsEngine.Plugin`'s `tournament_settings_entries/2`).

  Rendered by `settings_page/1`; it is public only because the pages that
  predate the frame used to call it themselves.
  """
  attr :tournament, :map, required: true
  attr :active, :any, required: true
  attr :current_scope, :any, default: nil

  def settings_subnav(assigns) do
    assigns = assign(assigns, :groups, nav_groups(assigns.tournament, assigns.current_scope))

    ~H"""
    <nav class="tset-nav" id="settings-nav" aria-label={gettext("Settings pages")}>
      <div :for={{heading, links} <- @groups} class="tset-nav-group">
        <span class="tset-nav-heading">{heading}</span>
        <%!-- A plugin's page is in its own live_session, so its link is a
              plain `href` (a page load either way) and its key a string,
              `"plugin:" <> id`. --%>
        <%= for {key, path, icon, label} <- links do %>
          <.link
            :if={is_atom(key)}
            navigate={path}
            class={["tset-nav-link", @active == key && "active"]}
            aria-current={@active == key && "page"}
          >
            <.icon name={icon} class="size-4" /> {label}
          </.link>

          <.link
            :if={is_binary(key)}
            href={path}
            id={"settings-nav-" <> String.replace(key, ":", "-")}
            class={["tset-nav-link", @active == key && "active"]}
            aria-current={@active == key && "page"}
          >
            <.icon name={icon} class="size-4" /> {label}
          </.link>
        <% end %>
      </div>
    </nav>
    """
  end

  defp nav_groups(tournament, scope) do
    tournament.id
    |> core_groups()
    |> add_plugin_entries(PairingsEngine.Plugins.tournament_settings_entries(scope, tournament))
  end

  # What a plugin adds goes at the end of the group it asks for.
  defp add_plugin_entries(groups, entries) do
    headings = %{
      setup: gettext("Set-up"),
      publishing: gettext("Publishing"),
      reporting: gettext("Reporting")
    }

    Enum.map(groups, fn {heading, links} ->
      extra =
        for entry <- entries, headings[entry.group] == heading do
          {"plugin:" <> entry.id, entry.path, entry.icon, entry.label}
        end

      {heading, links ++ extra}
    end)
  end

  defp core_groups(id) do
    [
      {gettext("Set-up"),
       [
         {:tournament, ~p"/t/#{id}/settings", "hero-trophy-micro", gettext("Tournament")},
         {:group, ~p"/t/#{id}/settings/group", "hero-squares-2x2-micro", gettext("Group")},
         {:options, ~p"/t/#{id}/settings/options", "hero-adjustments-vertical-micro",
          gettext("Options")},
         {:scoring, ~p"/t/#{id}/settings/scoring", "hero-calculator-micro", gettext("Scoring")},
         {:dates, ~p"/t/#{id}/settings/dates", "hero-calendar-days-micro", gettext("Dates")},
         {:rooms, ~p"/t/#{id}/settings/rooms", "hero-map-micro", gettext("Rooms")},
         {:categories, ~p"/t/#{id}/categories", "hero-tag-micro", gettext("Categories")},
         {:extra_points, ~p"/t/#{id}/settings/extra-points", "hero-plus-circle-micro",
          gettext("Extra points")},
         {:restrictions, ~p"/t/#{id}/settings/restrictions", "hero-no-symbol-micro",
          gettext("Forbidden pairings")}
       ]},
      {gettext("Publishing"),
       [
         {:results, ~p"/t/#{id}/settings/results", "hero-globe-alt-micro",
          gettext("OpenResults")},
         {:boards, ~p"/t/#{id}/settings/boards", "hero-signal-micro", gettext("Live boards")}
       ]},
      {gettext("Reporting"),
       [
         {:fide, ~p"/t/#{id}/settings/fide", "hero-flag-micro", "FIDE"},
         {:norms, ~p"/t/#{id}/settings/norms", "hero-identification-micro",
          gettext("Officials & norms")},
         {:export, ~p"/t/#{id}/settings/export", "hero-arrow-down-tray-micro", gettext("Export")},
         {:about, ~p"/t/#{id}/settings/about", "hero-information-circle-micro", gettext("About")}
       ]}
    ]
  end

  @doc """
  What `settings_page/1`'s `advanced` attr wants: whether the switch is on
  for this account, and how many advanced settings are not at their
  defaults (see `changed_count/2`).
  """
  def advanced(on?, changed), do: %{on?: on?, changed: changed}

  @doc """
  Like `advanced/2`, for a page that may have nothing advanced in it right
  now: with `has_advanced?` false the result is nil, and `settings_page/1`
  draws no switch. Each page answers `has_advanced?` for itself (a
  `has_advanced?/1` over its assigns), because what it renders can depend on
  the tournament's type, system or state - a switch that flips nothing is a
  small lie.
  """
  def advanced(_on?, _changed, false), do: nil
  def advanced(on?, changed, true), do: advanced(on?, changed)

  @doc """
  How many of `specs` are not at their defaults on `tournament`. Each spec
  is a field (compared with the schema's default), `{field, default}` when
  the schema's default is not the one a new tournament really starts with,
  or a plain boolean for something that is not a field at all (a logo, a
  group, a collaborator). `nil`, `""` and an empty list or map count as
  the same thing - an emptied field is at its default.
  """
  def changed_count(tournament, specs) do
    blank = %Tournament{}

    Enum.count(specs, fn
      flag when is_boolean(flag) ->
        flag

      {field, default} ->
        not same_value?(Map.get(tournament, field), default)

      field when is_atom(field) ->
        not same_value?(Map.get(tournament, field), Map.get(blank, field))
    end)
  end

  defp same_value?(a, b), do: (blank?(a) and blank?(b)) or a == b

  defp blank?(value), do: value in [nil, "", []] or value == %{}

  @doc """
  Mounts the "Show advanced settings" switch: assigns `show_advanced` from
  the account and handles the `"settings_advanced"` event every
  `settings_page/1` switch sends, storing the choice on the account. The
  event is halted here - no page handles it itself - and
  `attach_dirty_tracker/1` does not count it as an edit, because showing a
  field is not changing it.
  """
  def attach_advanced(socket) do
    user = scope_user(socket)

    socket
    |> Phoenix.Component.assign(show_advanced: match?(%{settings_advanced: true}, user))
    |> attach_hook(:settings_advanced, :handle_event, fn
      "settings_advanced", params, socket ->
        {:halt, put_advanced(socket, Map.get(params, "on") == "true")}

      _event, _params, socket ->
        {:cont, socket}
    end)
  end

  defp put_advanced(socket, on?) do
    socket = Phoenix.Component.assign(socket, show_advanced: on?)

    with %PairingsEngine.Accounts.User{} = user <- scope_user(socket),
         {:ok, user} <- PairingsEngine.Accounts.put_settings_advanced(user, on?) do
      Phoenix.Component.assign(socket,
        current_scope: %{socket.assigns.current_scope | user: user}
      )
    else
      _ -> socket
    end
  end

  defp scope_user(socket) do
    case socket.assigns[:current_scope] do
      %{user: user} -> user
      _ -> nil
    end
  end

  @doc """
  The answer under a settings form's Save button, the way the account page
  gives it: a tick and the note beside the button that caused it, read out
  by a screen reader, or the error in the same place. `class` keeps the
  `ok-note` / `error-note` hooks the tests and the older pages use.
  """
  attr :note, :string, default: nil
  attr :error, :string, default: nil
  attr :id, :string, default: nil

  def save_status(assigns) do
    ~H"""
    <span :if={@note} class="ok-note tset-saved" id={@id} role="status">
      <.icon name="hero-check-micro" class="size-4" /> {@note}
    </span>
    <span :if={@error} class="error-note tset-error" role="alert">{@error}</span>
    """
  end

  @doc """
  What a `Tournament.norm_event_type` value is called on screen, with the
  B.01 article it brings into play.
  """
  def norm_event_type_label("ordinary"),
    do: gettext("Ordinary event (B.01: 9 games, normal federation mix)")

  def norm_event_type_label("team_championship"),
    do: gettext("World or Continental Team Championship (B.01 1.4.1 b: 7 games if 7-9 rounds)")

  def norm_event_type_label("club_championship"),
    do: gettext("World or Continental Club Championship (B.01 1.4.1 b: 7 games if 7-9 rounds)")

  def norm_event_type_label("national_team_championship"),
    do:
      gettext(
        "National team championship (B.01 1.4.3 b: federation mix exempt for the registering federation's players)"
      )

  def norm_event_type_label("world_cup"),
    do: gettext("World Cup or Women's World Cup (B.01 1.4.1 b: 8 games)")

  def norm_event_type_label("national_championship"),
    do:
      gettext(
        "Final stage of a national championship (B.01 1.4.3 a: federation mix exempt for the registering federation's players)"
      )

  def norm_event_type_label("zonal"),
    do: gettext("Zonal or Sub-zonal tournament (B.01 1.4.3 c: federation mix exempt)")

  def norm_event_type_label(other), do: other

  @doc """
  A vertical run of settings - the only layout wrapper the Settings pages use.
  Holds `<.setting_field>`s and `<.setting_toggle>`s in DOM order, one per row.
  """
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def setting_group(assigns) do
    ~H"""
    <div class={["set-group", @class]} {@rest}>{render_slot(@inner_block)}</div>
    """
  end

  @doc """
  A feature behind its own on/off switch: the `switch` slot (a checkbox
  setting), then the settings that only mean something while it is on.
  With the box unticked the page shows the switch alone - the CSS reads the
  checkbox itself (`.tset-feature` in `app.css`), so ticking it opens the
  rest at once, before anything is saved, and every field stays in the form.

  `open` keeps the rest showing with the box unticked - for settings that
  are filled in anyway, which would otherwise be out of sight and still in
  force.
  """
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :open, :boolean, default: false
  slot :switch, required: true
  slot :inner_block

  def setting_feature(assigns) do
    ~H"""
    <div class={["tset-feature", @open && "is-open", @class]} id={@id}>
      <div class="tset-feature-switch">{render_slot(@switch)}</div>

      <div :if={@inner_block != []} class="tset-feature-body">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  @doc """
  A stacked setting: label above the control. The control itself is the slot,
  so a caller can pass a bare `<input>`, a `<select>`, or a `<select>` inside
  a `.locked-wrap` - plus any trailing `<.locked_hint_message>`.

  `required` renders the bold label + red asterisk used for
  `Tournament.required_setup_fields/0` members.
  """
  attr :label, :string, required: true
  attr :required, :boolean, default: false
  attr :hint, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def setting_field(assigns) do
    ~H"""
    <label class={["set-field", @class]} {@rest}>
      <span class={["set-label", @required && "req"]}>
        {@label}<span :if={@required} class="set-req"> *</span>
      </span>
      {render_slot(@inner_block)} <span :if={@hint} class="hint">{@hint}</span>
    </label>
    """
  end

  @doc """
  A checkbox setting: control beside its label, on its own full-width row.

  Always emits the hidden `value="false"` companion input Phoenix needs to
  see an unchecked box in the params. Pass `field` (plus `locked?` /
  `locked_hint`) to get the locked overlay + hint around the checkbox; the
  slot takes any extra trailing hint markup.
  """
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :checked, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :hint, :string, default: nil
  attr :field, :atom, default: nil
  attr :locked?, :boolean, default: false
  attr :locked_hint, :atom, default: nil
  attr :warning, :string, default: nil
  attr :class, :any, default: nil
  attr :id, :string, default: nil
  slot :inner_block

  def setting_toggle(assigns) do
    ~H"""
    <label class={["set-toggle", @class]} id={@id}>
      <input type="hidden" name={@name} value="false" />
      <span class="locked-wrap locked-wrap-inline">
        <input type="checkbox" name={@name} value="true" checked={@checked} disabled={@disabled} />
        <.locked_overlay :if={@field} field={@field} locked?={@locked?} />
      </span>

      <span class="set-toggle-text">
        {@label} <span :if={@hint} class="hint">{@hint}</span>
        <.locked_hint_message
          :if={@field}
          field={@field}
          locked_hint={@locked_hint}
          warning={@warning}
        /> {render_slot(@inner_block)}
      </span>
    </label>
    """
  end

  @doc """
  Shared by the "locked after first pairing" controls: a transparent div laid
  over the disabled control so a click still reaches something clickable and
  reports it via the "locked_hint" event. Renders nothing once unlocked.
  """
  attr :field, :atom, required: true
  attr :locked?, :boolean, required: true

  def locked_overlay(assigns) do
    ~H"""
    <div :if={@locked?} class="locked-overlay" phx-click="locked_hint" phx-value-field={@field}></div>
    """
  end

  @doc """
  The "why is this locked" panel, shown for the clicked field only: what
  changing it now actually costs (`warning`), and the way past the lock.

  `warning` is required and has no generic fallback, on purpose - "Are you
  sure?" tells an arbiter nothing they didn't already know from the field
  being disabled. What they need before they click past a round-1 freeze is
  the specific thing about to happen to rounds that already exist; every
  call site supplies its own (see `PairingsEngine.Tournaments.locked_fields/1`'s
  moduledoc for the reasoning behind each field this is called for).

  The "Unlock" button fires `"unlock_field"` with `phx-value-field={@field}`.
  Wire that event in the LiveView to add `@field` to whichever socket assign
  tracks fields unlocked for *this* editing session - never to the database,
  see `PairingsEngine.Tournaments.ensure_unlocked/3` for why a save still has
  to name it again. There is deliberately no page-wide "unlock everything"
  button here: unlocking is a decision about ONE field, made after reading
  what that one field costs, and a page-wide switch would let a single click
  wave every warning below through unread.
  """
  attr :field, :atom, required: true
  attr :locked_hint, :atom, default: nil
  attr :warning, :string, required: true

  attr :fide_path, :string,
    default: nil,
    doc:
      "Settings -> FIDE, when FIDE mode holds this field (`Tournaments.fide_locked_fields/1`): no Unlock then, only the way out"

  def locked_hint_message(assigns) do
    ~H"""
    <div :if={@locked_hint == @field} class="hint locked-hint-msg">
      <%= if @fide_path do %>
        <p style="margin: 0">
          <.fide_lock_text fide_path={@fide_path} />
        </p>
      <% else %>
        <p style="margin: 0 0 8px">{@warning}</p>

        <button
          type="button"
          class="pe-btn tonal"
          phx-click="unlock_field"
          phx-value-field={@field}
        >
          {gettext("Unlock")}
        </button>
      <% end %>
    </div>
    """
  end

  @doc """
  The line under a setting FIDE mode holds once round 1 is paired
  (`PairingsEngine.Tournaments.fide_locked_fields/1`) - for the pages whose
  controls have no click-to-explain overlay. Renders nothing unless one of
  `fields` is in `fide_locked`.

  It says why and gives the one way out, and has no Unlock button: VCL4THP
  wants these refused in FIDE mode (TEC's Level 5), and leaving FIDE mode is
  its own deliberate act on Settings -> FIDE.
  """
  attr :id, :string, required: true
  attr :tournament, :map, required: true
  attr :fide_locked, :list, required: true
  attr :fields, :list, required: true

  def fide_lock_note(assigns) do
    assigns =
      Phoenix.Component.assign(
        assigns,
        :locked?,
        Enum.any?(assigns.fields, &(&1 in assigns.fide_locked))
      )

    ~H"""
    <p :if={@locked?} id={@id} class="hint fide-lock-note">
      <.fide_lock_text fide_path={~p"/t/#{@tournament.id}/settings/fide"} />
    </p>
    """
  end

  attr :fide_path, :string, required: true

  defp fide_lock_text(assigns) do
    ~H"""
    <.rich_text text={
      gettext(
        "Locked in FIDE mode: the FIDE rules do not let this change once the first round is paired. To change it anyway, %[leave] first. That is for good, and the FIDE report says from which round."
      )
    }>
      <:part name="leave">
        <.link navigate={@fide_path}>{gettext("leave FIDE mode")}</.link>
      </:part>
    </.rich_text>
    """
  end

  # The word an arbiter has to type to force the hand-off lock open. Not
  # "DELETE" (which the recycle bin uses for a different, reversible act) and
  # not "YES": it names the thing being done, so a half-read confirmation
  # dialog still spells out what the typing is for.
  @force_unlock_word "UNLOCK"

  @doc "The word `force_unlock_panel/1` requires typed before it will submit."
  def force_unlock_word, do: @force_unlock_word

  @doc """
  Break glass: the affordance that forces a hand-off lock open without the
  token, for the copy that was stolen, wiped or dropped in a canal.

  Deliberately awkward, and deliberately quiet. It is folded away in a
  `<details>` rather than sitting next to "Take back", it is only rendered
  for the owner of a tournament that is actually handed off, and the button
  stays disabled until the word is typed - because the cost is not
  recoverable and a single mis-click must not be able to pay it.

  The copy is the point. "Are you sure?" is not what an arbiter needs to
  read here; what they need to read is the fact they are about to make true:
  **the other copy still exists, and from this moment nobody may open it
  again.** Unlocking here does not reach across and close it, and it does
  not merge anything back - see `PairingsEngine.Tournaments.force_take_back/2`.

  Wire the events up in the page that renders this:

    * `"force_unlock_input"` - `%{"confirm" => text}`, assigns
      `force_unlock_text`
    * `"force_unlock_confirmed"` - calls
      `Tournaments.force_take_back(tournament, current_scope)` and puts any
      `{:error, reason}` into `force_unlock_error` via `error_text/1`

  It lives in this module because it is the one place the web layer shares
  between the tournament-scoped pages; it is not a settings control, and it
  belongs wherever the rest of the hand-off UI ends up.
  """
  attr :tournament, :map, required: true
  attr :scope, :map, required: true
  attr :confirm_text, :string, default: ""
  attr :error, :string, default: nil

  def force_unlock_panel(assigns) do
    ~H"""
    <details
      :if={Tournaments.handed_off?(@tournament) and Tournaments.owner?(@tournament, @scope)}
      class="force-unlock"
    >
      <summary>{gettext("The copy this was handed to is gone")}</summary>

      <p class="hint">
        {gettext(
          "Taking this tournament back needs the token the other copy is holding. If that copy is lost for good - stolen, wiped, reinstalled - this opens the lock here instead."
        )}
      </p>

      <p class="error-note">
        {gettext(
          "The copy handed to %{place} still exists. This does not close it and does not merge anything back: whoever has it must never open it again, and anything entered there is lost.",
          place: handoff_destination(@tournament.handed_off_to)
        )}
      </p>

      <p class="hint">
        {gettext("Forcing the lock is recorded in this tournament's audit trail.")}
      </p>

      <form id="force-unlock-form" phx-change="force_unlock_input">
        <label class="field">
          <span>{gettext("Type %{word} to confirm", word: force_unlock_word())}</span>
          <input name="confirm" value={@confirm_text} autocomplete="off" />
        </label>
      </form>

      <p :if={@error} class="error-note">{@error}</p>

      <div class="actions">
        <button
          type="button"
          class="pe-btn danger"
          phx-click="force_unlock_confirmed"
          disabled={@confirm_text != force_unlock_word()}
        >
          {gettext("Unlock without the token")}
        </button>
      </div>
    </details>
    """
  end

  # `hand_off/2` trims the label it is given, so a caller who typed nothing
  # (or only spaces) leaves `""`, not nil - and `""` is perfectly truthy, so
  # `label || default` would render "The copy handed to  still exists." The
  # sentence has to name somewhere, even when the somewhere is unknown.
  defp handoff_destination(label) when is_binary(label) do
    case String.trim(label) do
      "" -> gettext("another copy")
      trimmed -> trimmed
    end
  end

  defp handoff_destination(_label), do: gettext("another copy")

  @doc """
  What a tournament's settings currently say about FIDE handling, and what
  to change to say something else.

  Modelled on the setup checklist on PairingsLive (`missing_setup_fields/1`),
  deliberately: a card, a sentence saying what it is, and one line per item
  linking to the page that item lives on. That is the vocabulary this app
  already uses for "here is what is not right yet", and an arbiter has read
  it before.

  **It does not, and must not, argue.** An arbiter running a club evening
  that will never be sent to FIDE has every right to pair by category or run
  a Keizer ladder, and the software's job is to say what that means, once,
  and get out of the way. Nothing here blocks anything; there is no
  "fix it" button and no confirmation to click past.

  `show_compliant` makes it say something when there is nothing wrong -
  wanted on Settings → FIDE, which is where somebody goes to ask the
  question, and not wanted on the pages that merely happen to host one of
  the settings. FIDE handling is the default (`VCL.01`), so a banner
  announcing it on every page would be noise that teaches people to skip
  banners.
  """
  attr :tournament, :map, required: true
  attr :show_compliant, :boolean, default: false

  def compliance_notice(assigns) do
    assigns = Phoenix.Component.assign(assigns, :departures, Compliance.check(assigns.tournament))

    ~H"""
    <div
      :if={@departures != []}
      class="card"
      style="display: block; margin: 12px 0; border-left: 3px solid var(--accent)"
    >
      {gettext(
        "This tournament is no longer set up the way the FIDE pairing rules describe. That is allowed - an event nobody is sending to FIDE can be run however you like - but a FIDE report from it records that it happened, and in which round."
      )}
      <ul style="margin: 6px 0 0; padding-left: 20px">
        <li :for={departure <- @departures}>
          <.link navigate={compliance_setting_path(@tournament, departure.setting)}>
            {compliance_setting_label(departure.setting)}
          </.link>
          - {compliance_message(departure.code)}
        </li>
      </ul>

      <p :if={@tournament.fide_compliance_lost_round} class="hint" style="margin: 8px 0 0">
        {compliance_lost_line(@tournament.fide_compliance_lost_round)}
      </p>
    </div>

    <p :if={@show_compliant and @departures == [] and is_nil(@tournament.fide_compliance_lost_round)}>
      {gettext(
        "This tournament is in FIDE mode: set up the way the FIDE pairing rules describe. There is nothing to switch on: that is what a new tournament gets. Changing a setting the rules do not allow takes it out, and so does leaving FIDE mode below."
      )}
    </p>

    <p
      :if={@show_compliant and @departures == [] and @tournament.fide_compliance_lost_round != nil}
      class="error-note"
    >
      {compliance_lost_line(@tournament.fide_compliance_lost_round)} {gettext(
        "Its settings match the FIDE rules, but there is no way back into FIDE mode: that is a fact about this tournament's history and it stands."
      )}
    </p>
    """
  end

  # Round 0 is a real value and means "before round 1 was paired" - a Keizer
  # tournament is not FIDE-paired from the moment it is created. "In round 0"
  # would read as a bug, so it gets its own sentence.
  defp compliance_lost_line(0),
    do: gettext("Recorded: this tournament left FIDE mode before the first round was paired.")

  defp compliance_lost_line(round),
    do: gettext("Recorded: this tournament left FIDE mode in round %{round}.", round: round)

  @doc """
  The one-line label for a compliance setting - the link text in
  `compliance_notice/1`.

  Not what the audit trail shows: `AuditLive.describe/1` renders the raw
  field name, because the trail is evidence and a row that reads differently
  depending on the reader's language is worse evidence than one that always
  says `swiss_match_format`.
  """
  def compliance_setting_label(:pairing_system), do: gettext("Pairing system")
  def compliance_setting_label(:pair_by_category), do: gettext("Pair by category")
  def compliance_setting_label(:swiss_match_format), do: gettext("Match format")

  def compliance_setting_label(:late_entry_numbering),
    do: gettext("Late entrants' pairing numbers")

  def compliance_setting_label(:postponed_requester_outcome),
    do: gettext("Postponed game, for the player who postponed it")

  def compliance_setting_label(:postponed_opponent_outcome),
    do: gettext("Postponed game, for the opponent")

  def compliance_setting_label(:points_draw), do: gettext("Points for a draw")
  def compliance_setting_label(:bye_value), do: gettext("Pairing-allocated bye")

  def compliance_setting_label(:soft_position),
    do: gettext("How hard to try the wishes")

  @doc """
  What one `PairingsEngine.Compliance` code means, in an arbiter's words.

  Lives here rather than in `Compliance` because the domain layer does not
  use gettext and must not start: a warning that cannot be translated is a
  warning half this app's users cannot read. `Compliance` returns codes;
  this is the only place they become sentences.
  """
  def compliance_message(:non_fide_pairing_system),
    do:
      gettext(
        "FIDE defines the Swiss (C.04.3) and the round-robin Berger tables (C.05); it does not define a Keizer ladder, and the FIDE tie-breaks do not apply to one. Swiss or round robin puts this back."
      )

  def compliance_message(:categories_paired_separately),
    do:
      gettext(
        "Each category is paired as a separate tournament and the results are merged into one round, so two players on the same score never meet if they are in different categories. That is not a pairing C.04.3 can produce for one field of players. Running the sections as separate tournaments does the same thing without this."
      )

  def compliance_message(:postponed_requester_not_draw),
    do:
      gettext(
        "A postponed game counts as something other than a draw for the player who postponed it. FIDE allows only a draw until the game is played. A draw puts this back."
      )

  def compliance_message(:postponed_opponent_not_draw),
    do:
      gettext(
        "A postponed game counts as something other than a draw for the opponent. FIDE allows only a draw until the game is played. A draw puts this back."
      )

  def compliance_message(:draws_outscore_win),
    do:
      gettext(
        "Two draws are worth more than a win and a loss together. A game cannot give more than a win does (Laws of Chess 10.2), so FIDE does not accept this scoring. A draw worth at most half of a win plus a loss puts this back."
      )

  def compliance_message(:bye_above_win),
    do:
      gettext(
        "The pairing-allocated bye is worth more than a win, which no game can give (Laws of Chess 10.2). A bye worth a win, a draw or a loss puts this back."
      )

  def compliance_message(:bye_not_a_game_score),
    do:
      gettext(
        "With the standard 1, ½, 0 scoring, the pairing-allocated bye is worth something a game cannot give. A bye worth 1, ½ or 0 puts this back."
      )

  def compliance_message(:late_entrants_after_field),
    do:
      gettext(
        "A player who joins late is numbered after the field instead of where their rating puts them, so every later round is paired on numbers the FIDE rules (C.04.2 2.4) would not have given. By rating puts this back."
      )

  def compliance_message(:prohibition_changed_after_round_1),
    do:
      gettext(
        "Round 1 is paired. How hard the wishes are tried is part of what was announced about them, and the FIDE rules (C.05 5.2) want restrictions announced before the first round."
      )

  def compliance_message(:mirrored_second_leg),
    do:
      gettext(
        "The second game of each match is a colour-reversed copy of the first, with no pairing decision behind it, so half of this tournament's rounds were not paired by C.04.3 at all."
      )

  @doc """
  Which page hosts a given `PairingsEngine.Compliance` setting - the
  compliance counterpart of `setup_field_path/2`, and separate from it
  because the two lists have no reason to stay the same.
  """
  def compliance_setting_path(tournament, :pair_by_category),
    do: ~p"/t/#{tournament.id}/categories"

  def compliance_setting_path(tournament, setting)
      when setting in [
             :postponed_requester_outcome,
             :postponed_opponent_outcome,
             :points_draw,
             :bye_value
           ],
      do: ~p"/t/#{tournament.id}/settings/scoring"

  # pairing_system, swiss_match_format and late_entry_numbering all live on
  # the Options page.
  def compliance_setting_path(tournament, _setting),
    do: ~p"/t/#{tournament.id}/settings/options"

  @doc """
  Records one "tournament.fide_compliance_lost" audit row per compliance
  departure a save actually introduced - never for one that was already
  there, and never for a save that left them alone.

  Deliberately its own audit action rather than folded into
  `log_settings_change/3`'s bulk diff, for the same reason
  `log_unlocked_field_changes/4` is: the round this happened in is the one
  fact about it FIDE asks for by name, and it must not go unnoticed inside
  whatever else that same "Save" also touched. Call this alongside the bulk
  diff, not instead of it.

  `details.round` is read back off the tournament rather than counted here,
  so the trail and `fide_compliance_lost_round` can never disagree about
  which round it was - `Tournaments` writes that column in the same
  changeset as the save itself.
  """
  def log_compliance_departures(socket, before, after_tournament) do
    for departure <- Compliance.introduced(before, after_tournament) do
      Audit.log(
        after_tournament.id,
        socket.assigns.current_scope,
        "tournament.fide_compliance_lost",
        %{
          setting: to_string(departure.setting),
          code: to_string(departure.code),
          round: after_tournament.fide_compliance_lost_round
        }
      )
    end

    :ok
  end

  ## ---------- leaving FIDE mode: TEC's Level-4 double confirmation ----------
  #
  # VCL4THP Q43. Every way out of FIDE mode asks twice before it acts: a
  # first message saying the act is not compliant, then a second one spelling
  # out what it costs, answered the opposite way round from the first. The
  # explicit "Leave FIDE mode" button, a settings save that departs and a
  # pairing that departs all use `fide_exit_dialog/1`.

  @doc """
  Makes a page ask before a save takes the tournament out of FIDE mode
  (`fide_gate/5`) and answers the dialog's three events. Call it once in
  `mount/3`.

  The gate remembers the event it held back and runs it again, once, when
  the second confirmation comes; cancelling at either step drops it and
  nothing was saved. The server holds the step, so a confirm that skipped the
  first message is ignored.
  """
  def attach_fide_gate(socket) do
    socket
    |> Phoenix.Component.assign(fide_gate: nil, fide_gate_confirmed: false)
    |> attach_hook(:fide_gate, :handle_event, &fide_gate_event/3)
  end

  defp fide_gate_event("fide_gate_continue", _params, socket) do
    case socket.assigns.fide_gate do
      %{step: :warn} = gate ->
        {:halt, Phoenix.Component.assign(socket, fide_gate: %{gate | step: :consequences})}

      _ ->
        {:halt, socket}
    end
  end

  defp fide_gate_event("fide_gate_cancel", _params, socket),
    do: {:halt, Phoenix.Component.assign(socket, fide_gate: nil)}

  defp fide_gate_event("fide_gate_confirm", _params, socket) do
    case socket.assigns.fide_gate do
      %{step: :consequences, event: event, payload: payload} = gate ->
        socket =
          Phoenix.Component.assign(
            socket,
            [fide_gate: nil, fide_gate_confirmed: true] ++ Map.get(gate, :restore, [])
          )

        {:noreply, socket} = socket.view.handle_event(event, payload, socket)
        {:halt, Phoenix.Component.assign(socket, fide_gate_confirmed: false)}

      _ ->
        {:halt, socket}
    end
  end

  defp fide_gate_event(_event, _params, socket), do: {:cont, socket}

  @doc """
  Asks before saving `params` over `base` when that would take the tournament
  out of FIDE mode: `:proceed` when it would not (or the arbiter has just
  confirmed), otherwise `{:noreply, socket}` with the first Level-4 message
  up. `event` and `payload` are the event being handled, kept to run again on
  the second confirmation.
  """
  def fide_gate(socket, event, payload, base, params) do
    if socket.assigns[:fide_gate_confirmed] do
      :proceed
    else
      case Tournaments.fide_departures(base, params) do
        [] ->
          :proceed

        departures ->
          reasons =
            for d <- departures,
                do: {compliance_setting_label(d.setting), compliance_message(d.code)}

          {:noreply,
           Phoenix.Component.assign(socket, fide_gate: new_gate(event, payload, reasons))}
      end
    end
  end

  @doc "The gate a page holds while it asks - `step` is `:warn`, then `:consequences`."
  def new_gate(event, payload, reasons, restore \\ []),
    do: %{step: :warn, event: event, payload: payload, reasons: reasons, restore: restore}

  @doc """
  What a pairing that departs from the FIDE rules did, as `{label, sentence}`
  pairs for `fide_exit_dialog/1` - one per kind `Pairing.pairing_deviations/2`
  names.
  """
  def deviation_reasons(kinds), do: Enum.map(kinds, &deviation_reason/1)

  defp deviation_reason(:bye_exclusion),
    do:
      {gettext("Bye exclusion"),
       gettext(
         "A bye exclusion moves the pairing-allocated bye away from the player the FIDE rules would give it to."
       )}

  defp deviation_reason(:bye_preference),
    do:
      {gettext("Bye preference"),
       gettext(
         "A bye preference moves the pairing-allocated bye away from the player the FIDE rules would give it to."
       )}

  defp deviation_reason(:soft_pairs),
    do:
      {gettext("Soft pairing rules"),
       gettext(
         "An \"only if possible\" pairing wish moves a board away from where the FIDE rules put it."
       )}

  defp deviation_reason(:extra_points),
    do:
      {gettext("Extra points in the pairing"),
       gettext("Extra points are counted in the pairing, which the FIDE rules do not do.")}

  @doc """
  The Level-4 double confirmation for leaving FIDE mode. Shows nothing while
  `step` is nil; `:warn` is the first message ("this is not compliant -
  continue?"), `:consequences` the second, answered the opposite way round
  ("stay in FIDE mode?"). `reasons` is what departs, as `{label, sentence}`
  pairs; it is empty for the explicit way out, which departs from nothing in
  particular. The three events and the `id` prefix are the caller's, so each
  page keeps its own element ids.
  """
  attr :id, :string, required: true
  attr :step, :atom, default: nil
  attr :reasons, :list, default: []
  attr :continue_event, :string, default: "fide_gate_continue"
  attr :cancel_event, :string, default: "fide_gate_cancel"
  attr :confirm_event, :string, default: "fide_gate_confirm"

  def fide_exit_dialog(assigns) do
    ~H"""
    <div
      :if={@step}
      id={@id}
      class="modal-overlay"
      phx-window-keydown={@cancel_event}
      phx-key="escape"
    >
      <div
        id={"#{@id}-card"}
        class="modal-card"
        style="max-width: 560px"
        role="alertdialog"
        aria-modal="true"
        aria-labelledby={"#{@id}-title"}
        tabindex="-1"
        phx-hook="DialogFocus"
        data-dialog
      >
        <h2 id={"#{@id}-title"}>{gettext("Leave FIDE mode?")}</h2>

        <div :if={@step == :warn} id={"#{@id}-warn"}>
          <p style="margin: 0 0 8px">
            <strong>{gettext("This is not compliant with the FIDE regulations.")}</strong> {gettext(
              "A tournament outside FIDE mode can be changed in ways the FIDE pairing rules do not allow. Do you want to continue?"
            )}
          </p>

          <div :if={@reasons != []} id={"#{@id}-reasons"}>
            <p style="margin: 0 0 6px">
              <strong>{gettext("This is what takes it out of FIDE mode:")}</strong>
            </p>

            <ul style="margin: 0 0 10px; padding-left: 20px">
              <li :for={{label, sentence} <- @reasons}><strong>{label}</strong> - {sentence}</li>
            </ul>
          </div>

          <div class="actions">
            <button id={"#{@id}-continue"} type="button" class="pe-btn" phx-click={@continue_event}>
              {gettext("Yes, continue")}
            </button>

            <button
              id={"#{@id}-cancel"}
              type="button"
              class="pe-btn primary"
              phx-click={@cancel_event}
            >
              {gettext("Cancel")}
            </button>
          </div>
        </div>

        <div :if={@step == :consequences} id={"#{@id}-consequences"}>
          <p style="margin: 0 0 6px"><strong>{gettext("What leaving FIDE mode does:")}</strong></p>

          <ul style="margin: 0 0 8px; padding-left: 20px">
            <li>{gettext("It is for good: this tournament can never return to FIDE mode.")}</li>

            <li>
              {gettext(
                "The FIDE report (TRF) says from which round the tournament was no longer in FIDE mode, so whoever checks it knows where to look harder."
              )}
            </li>

            <li>
              {gettext(
                "The locked settings and every earlier round can then be changed, and the program no longer stops a change the FIDE rules forbid."
              )}
            </li>

            <li>{gettext("Every page of this tournament will say it is not in FIDE mode.")}</li>
          </ul>

          <p style="margin: 0 0 8px"><strong>{gettext("Stay in FIDE mode?")}</strong></p>

          <div class="actions">
            <button id={"#{@id}-stay"} type="button" class="pe-btn primary" phx-click={@cancel_event}>
              {gettext("Yes, stay in FIDE mode")}
            </button>

            <button
              id={"#{@id}-confirm"}
              type="button"
              class="pe-btn danger"
              phx-click={@confirm_event}
            >
              {gettext("No, leave FIDE mode")}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  The "this tournament was updated elsewhere while you were editing" banner,
  shown when `@stale` is set on the pages carrying an always-open
  `@tournament`-bound form.
  """
  attr :stale, :boolean, required: true

  def stale_banner(assigns) do
    ~H"""
    <p :if={@stale} class="error-note">
      {gettext(
        "This tournament was updated elsewhere while you were editing. Saving will overwrite that change with what's on this page - reload the page first if you want to see it instead."
      )}
    </p>
    """
  end

  @doc """
  Attaches the `:settings_dirty_tracker` hook: flips `dirty` true (and clears
  any transient `locked_hint`) the moment any event fires, except the
  `"locked_hint"` event itself (clicking a disabled control's overlay to see
  *why* it's locked isn't an edit). See the mount of any Settings page.
  """
  def attach_dirty_tracker(socket) do
    attach_hook(socket, :settings_dirty_tracker, :handle_event, fn
      "locked_hint", _params, socket ->
        {:cont, socket}

      # Showing the advanced settings changes what is on screen, not what
      # is in the form - see `attach_advanced/1`.
      "settings_advanced", _params, socket ->
        {:cont, socket}

      _event, _params, socket ->
        {:cont, Phoenix.Component.assign(socket, dirty: true, locked_hint: nil)}
    end)
  end

  @doc """
  The dirty-branch handler for a `{:tournament_changed, ...}` broadcast: the
  local form is dirty, so reloading would clobber in-progress edits. Only
  flag the page `stale` when the freshly-loaded row actually differs from
  what's already assigned (comparing full structs sidesteps `updated_at`'s
  second-level precision) - a broadcast could just be the echo of our own
  child-table write (forbidden pairings, exclusions), which doesn't touch the
  `tournaments` row itself.
  """
  def handle_stale_check(socket) do
    case Tournaments.get_authorized_tournament(
           socket.assigns.current_scope,
           socket.assigns.tournament.id
         ) do
      nil ->
        {:noreply, Phoenix.Component.assign(socket, stale: true)}

      tournament ->
        if tournament == socket.assigns.tournament do
          {:noreply, socket}
        else
          {:noreply, Phoenix.Component.assign(socket, stale: true)}
        end
    end
  end

  @doc """
  Records a "tournament.settings_updated" audit row with the before/after
  diff of only the fields that actually changed - a no-op when nothing
  tracked changed (e.g. a "Save" that touched only ignored/derived fields).
  """
  def log_settings_change(socket, before, after_tournament) do
    changed = tournament_diff(before, after_tournament)

    if changed != %{} do
      Audit.log(
        after_tournament.id,
        socket.assigns.current_scope,
        "tournament.settings_updated",
        %{changed_fields: changed}
      )
    end
  end

  @doc """
  Records one "tournament.locked_field_changed" audit row per field in
  `fields` that actually changed value - `fields` being the real
  `Tournaments.locked_fields/1` atoms an arbiter deliberately unlocked for
  this one save (see `locked_hint_message/1`'s "Unlock" button), never the
  whole diff.

  Deliberately its own audit action rather than folded into
  `log_settings_change/3`'s bulk diff: overriding a round-1 freeze is a
  significant act mid-event on its own, one an arbiter may need to point to
  later, and it must not go unnoticed inside whatever else that same "Save"
  also happened to touch. Call this alongside `log_settings_change/3`, not
  instead of it - the bulk diff still belongs in the trail too.
  """
  def log_unlocked_field_changes(socket, before, after_tournament, fields) do
    # NOT a `for` with `old_value = ...`/`new_value = ...` bindings as filter
    # clauses: `for`'s non-generator clauses are filters on the TRUTHINESS of
    # what they evaluate to, not merely "does this match" - so the moment a
    # previously-unset field (e.g. `abs_value` before its first-ever save,
    # `nil`) hit `old_value = Map.get(before, field)`, that clause's value
    # (`nil`) read as a failing filter and silently dropped the iteration
    # before the real `!=` check ever ran. `Enum.each/2` with an explicit
    # `if` has no such trap.
    Enum.each(fields, fn field ->
      old_value = Map.get(before, field)
      new_value = Map.get(after_tournament, field)

      if old_value != new_value do
        Audit.log(
          after_tournament.id,
          socket.assigns.current_scope,
          "tournament.locked_field_changed",
          %{field: to_string(field), from: old_value, to: new_value}
        )
      end
    end)

    :ok
  end

  @doc "Field-by-field diff of two tournament structs, skipping derived/internal fields."
  def tournament_diff(before, after_tournament) do
    fields = Tournament.__schema__(:fields) -- @settings_diff_ignore

    for field <- fields,
        Map.get(before, field) != Map.get(after_tournament, field),
        into: %{} do
      {to_string(field), [Map.get(before, field), Map.get(after_tournament, field)]}
    end
  end

  @doc """
  One line saying what a Swiss's initial colour is and where it came from -
  "Initial colour: drawn by lot: White", or set by the arbiter - for the
  Pairings and Settings pages. nil while the setting is "drawn by lot" and
  nothing has been drawn yet.
  """
  def initial_colour_status(%Tournament{initial_colour: "white"}),
    do: gettext("Initial colour: White, set by the arbiter")

  def initial_colour_status(%Tournament{initial_colour: "black"}),
    do: gettext("Initial colour: Black, set by the arbiter")

  def initial_colour_status(%Tournament{initial_colour_drawn: "white"}),
    do: gettext("Initial colour: drawn by lot: White")

  def initial_colour_status(%Tournament{initial_colour_drawn: "black"}),
    do: gettext("Initial colour: drawn by lot: Black")

  def initial_colour_status(_tournament), do: nil

  @doc """
  The words for each step of the automation (`Tournament`'s
  `@publish_modes`) - the stops of the "Automatically:" slider on Settings ->
  OpenResults and the options of the account's default.
  """
  def auto_publish_label("manual"), do: gettext("By hand")
  def auto_publish_label("pairings"), do: gettext("Pairings once paired")
  def auto_publish_label("results"), do: gettext("+ results live")
  def auto_publish_label("standings"), do: gettext("+ standings when the round is finished")
  def auto_publish_label(other), do: other

  @doc "The label of one `initial_colour` setting value."
  def initial_colour_label("lot"), do: gettext("Drawn by lot (default)")
  def initial_colour_label("white"), do: gettext("White")
  def initial_colour_label("black"), do: gettext("Black")

  defp team_reason_text(reason) do
    Logger.warning("team pairing failed: #{inspect(reason)}")
    gettext("see the server log for the details")
  end

  @doc """
  A changeset field as a person says it, in the current language. A field
  that has no entry here is humanised (`birth_year` -> `birth year`).
  """
  def changeset_field_label(:name), do: gettext("Name")
  def changeset_field_label(:fide_id), do: gettext("FIDE ID")
  def changeset_field_label(:fide_rating), do: gettext("FIDE rating")
  def changeset_field_label(:national_rating), do: gettext("National rating")
  def changeset_field_label(:national_id), do: gettext("National ID")
  def changeset_field_label(:birth_year), do: gettext("Birth year")
  def changeset_field_label(:federation), do: gettext("Federation")
  def changeset_field_label(:email), do: gettext("Email")
  def changeset_field_label(:club), do: gettext("Club")
  def changeset_field_label(:title), do: gettext("Title")
  def changeset_field_label(:sex), do: gettext("Sex")
  def changeset_field_label(field), do: field |> to_string() |> String.replace("_", " ")

  @doc """
  Human-readable error string for whatever a context write returned.

  Usually an `Ecto.Changeset`, but the context also returns bare reason atoms
  - notably `:archived` and `:handed_off` from
  `Tournaments.ensure_writable/1`, which every write path can now return.
  Before this had an atom clause, an archived tournament's settings save
  crashed the LiveView outright: `changeset.errors` on the atom `:archived`
  parses as a remote call to `:archived.errors/0`.

  Every reason a user can actually meet gets a clause of its own. The
  fallback below - the atom with its underscores rubbed out - is a last
  resort, and it is a bad one: `:handed_off` reached it and rendered as the
  bare words "handed off", which names the state without naming the remedy
  and reads like a fragment of a sentence somebody forgot to finish. An
  arbiter meeting a refusal needs to know what is true and what to do about
  it, and both fit in one line.
  """
  # A new team tournament with Keizer (`Tournament.validate_no_team_keizer/1`)
  # gets its own sentence; every other changeset its field errors.
  def error_text(%Ecto.Changeset{errors: errors}) do
    validation? = fn kind ->
      Enum.any?(errors, fn {_field, {_msg, opts}} -> opts[:validation] == kind end)
    end

    cond do
      validation?.(:round_one_paired) ->
        gettext(
          "Not saved: round 1 is already paired, so round-1 absentees can no longer be switched between late entries and numbered-with-the-field. Doing so would renumber players in rounds already played."
        )

      validation?.(:team_keizer) ->
        gettext(
          "Keizer cannot pair team against team, so a team tournament cannot use it. Choose Swiss (FIDE's team Swiss, C.04.6) or Round robin."
        )

      true ->
        Enum.map_join(errors, ", ", fn {field, {msg, opts}} ->
          "#{changeset_field_label(field)} #{PairingsEngineWeb.CoreComponents.translate_error({msg, opts})}"
        end)
    end
  end

  def error_text(:locked_in_fide_mode),
    do:
      gettext(
        "Not saved: this setting is locked in FIDE mode once the first round is paired. Leave FIDE mode under Settings, FIDE to change it."
      )

  def error_text(:locked_after_pairing),
    do:
      gettext(
        "Not saved: a setting that is locked once the first round is paired was changed. Unlock it first."
      )

  def error_text(:not_in_fide_mode),
    do: gettext("This tournament is not in FIDE mode, so there is nothing to leave.")

  def error_text(:round_closed_in_fide_mode),
    do:
      gettext(
        "Not saved: in FIDE mode only the last two rounds played can be changed (C.04.2:4.3). A mistake found later is corrected after the tournament, for the rating report only."
      )

  # ---- team workflow (docs/team-tournaments.md) ----

  def error_text(:roster_locked_in_fide_mode),
    do:
      gettext(
        "Not changed: in FIDE mode the teams' rosters and board orders are fixed once round 1 is paired. A new player can still be added at the bottom of a team, as a reserve."
      )

  def error_text(:match_started),
    do:
      gettext(
        "Not changed: this match already has a result. Line-ups and home and away can only change before the first result of the match is entered."
      )

  def error_text(:not_home_and_away),
    do:
      gettext(
        "Home and away only exist with league-style board colours (Teams - Matches - Board colours)."
      )

  def error_text(:games_played),
    do:
      gettext(
        "Not recorded: a game of this match was played, so it is not a match neither team turned up for. Forfeit it to one team instead."
      )

  def error_text(:gap),
    do:
      gettext(
        "Not saved: a line-up fills the boards from board 1 down. A team short of players leaves the bottom boards empty, not one in the middle."
      )

  def error_text(:no_players),
    do:
      gettext(
        "Not saved: neither team has a player on any board. A match neither team plays is a double forfeit."
      )

  def error_text({:board_order, upper, lower}),
    do:
      gettext(
        "Not saved: %{lower} is above %{upper} in the team's board order, so %{lower} must play on a higher board than %{upper}. A line-up keeps the roster's order; players may only be left out.",
        upper: upper.name,
        lower: lower.name
      )

  def error_text({:unavailable, player}),
    do:
      gettext(
        "Not saved: %{player} cannot play this round (withdrawn, absent or not yet started).",
        player: player.name
      )

  def error_text({:twice, player}),
    do: gettext("Not saved: %{player} is on two boards.", player: player.name)

  def error_text({:not_on_team, _id}),
    do: gettext("Not saved: a player in the line-up is not on that team.")

  def error_text(:board_changed),
    do:
      gettext(
        "Not saved: this board changed - somebody else changed its players while this page was open. Reload the page and enter the result on the board as it is now."
      )

  def error_text(:match_score_set),
    do:
      gettext(
        "Not changed: this match was decided by its score. Withdraw the match score on the match's page first."
      )

  def error_text(:match_decided),
    do:
      gettext(
        "Not changed: this match was decided as a whole (forfeited to one team, or a double forfeit). Withdraw the decision on the Pairings page first."
      )

  def error_text(:nobody_to_seat),
    do:
      gettext(
        "Not withdrawn: neither team can field a player in this round, so the match would be one nobody plays again. Mark the team or its players available for the round first, then withdraw the decision."
      )

  def error_text(:not_optional),
    do:
      gettext(
        "A match score is for a team event whose line-ups are optional (Settings - Options - Teams)."
      )

  def error_text(:players_seated),
    do:
      gettext(
        "Not saved: players sit at this match's boards. Enter each board's result instead, or empty the line-ups first."
      )

  def error_text(:bad_score),
    do:
      gettext(
        "Not saved: a match score is two numbers in steps of a half that add up to the number of boards, such as 2.5 and 1.5 on four boards."
      )

  def error_text(:no_match_score), do: gettext("This match has no match score to withdraw.")

  def error_text(:round_paired),
    do:
      gettext(
        "That round is already paired. Change it on the Pairings page: forfeit the team's match by decision."
      )

  def error_text(:already_withdrawn), do: gettext("This team has already withdrawn.")

  def error_text(:not_withdrawn), do: gettext("This team has not withdrawn.")

  def error_text(:bad_round), do: gettext("Choose a round of this tournament.")

  def error_text(:half_bye_not_eligible),
    do:
      gettext(
        "This player is marked not eligible for half-point byes (C.05:6.7.4). Pick another bye."
      )

  def error_text(:player_in_closed_round),
    do:
      gettext(
        "Not deleted: this player played in a round that FIDE mode no longer lets change, and deleting them would empty their seat there. Withdraw them instead."
      )

  def error_text(:archived),
    do: gettext("This tournament is archived - unarchive it to make changes.")

  def error_text(:handed_off),
    do:
      gettext(
        "This tournament has been handed off to another copy of the app and is read-only here - take it back to make changes."
      )

  # Deliberately blunt. This is the one refusal an arbiter may be reading
  # mid-round with players waiting, so it says what did NOT happen first,
  # and what to do about it second. The screen behind it has already been
  # re-read from the database, so what is shown is what is stored.
  def error_text(:database_busy),
    do:
      gettext(
        "NOT SAVED - the database was busy and would not accept the change. " <>
          "Nothing was written. Try again; if it keeps happening, a rating " <>
          "list sync is probably running - wait for it to finish."
      )

  def error_text(:not_owner),
    do: gettext("Only the owner of this tournament can do that.")

  # A category write naming something that is not one of the tournament's
  # categories. In practice this means the page was open while somebody else
  # removed the category, so the remedy is a reload rather than anything the
  # arbiter has to fix - and the atom fallback's "unknown category" would
  # have said neither.
  def error_text(:unknown_category),
    do:
      gettext(
        "That category is not one of this tournament's - it may have just been removed on the Categories page. Reload and try again."
      )

  # A permanent delete that was refused because the tournament is still up on
  # the results site and could not be taken down. The server's own words are
  # carried through rather than summarised - "connection timed out" and "the
  # results site refused this tournament's key" send an arbiter to completely
  # different places, and the refusal is only useful if it says which.
  def error_text({:still_published, message}) when is_binary(message),
    do:
      gettext(
        "Nothing was deleted. This tournament is still published on the results site and could not be taken down: %{message}",
        message: message
      )

  def error_text(:not_handed_off),
    do: gettext("This tournament is not handed off, so there is no lock to force open.")

  def error_text(:bad_token),
    do:
      gettext(
        "That is not the token this tournament was handed off with - it is the one the other copy carries back."
      )

  def error_text(:already_handed_off),
    do:
      gettext(
        "This tournament is already handed off to another copy - take it back before handing it anywhere else."
      )

  # The organiser's bye exclusions left no legal round (not a FIDE rule -
  # docs/pairing-systems.md). The Pairings page shows its own panel for
  # this, naming the players and offering to pair anyway; this sentence is
  # for anywhere else the refusal surfaces.
  def error_text({:bye_exclusions, %{excluded: excluded}}) when is_list(excluded),
    do:
      ngettext(
        "No legal pairing keeps the pairing-allocated bye away from the player excluded from it. Nothing was paired.",
        "No legal pairing keeps the pairing-allocated bye away from the %{count} players excluded from it. Nothing was paired.",
        length(excluded)
      )

  # Pairing a tournament that has nothing left to pair, from any of the three
  # systems. A reason rather than a sentence because round robin's
  # pair-everything loop stops on it - it used to recognise the sentence by
  # its first word, "All". The count is the tournament's round count, so a
  # one-round event does not read "All 1 rounds".
  def error_text({:all_rounds_paired, rounds}) when is_integer(rounds),
    do:
      ngettext(
        "The only round has already been paired",
        "All %{count} rounds have already been paired",
        rounds
      )

  # The team Swiss engine's own refusals (`PairingsEngine.TeamSwiss`,
  # `Ainalrami.TeamPairing.pair_round/2`) and its crash guard. Every one of
  # these leaves the round unpaired and the tournament unchanged - the
  # wording says so, and what the arbiter can do next: try again, pair by
  # hand, or (for the search limit) contact support on a very large event.
  def error_text({:team_pairing, :budget_exhausted, round}),
    do:
      gettext(
        "Ainalrami couldn't finish the pairing for round %{round} within its search limit. The round was not paired and nothing changed. You can try again, pair this round manually (hand edits), or, for a very large event, contact support.",
        round: round
      )

  def error_text({:team_pairing, :no_legal_pairing, round}),
    do:
      gettext(
        "Round %{round} can't be paired under FIDE's rules: every possible pairing breaks an absolute criterion, for example teams meeting twice. This usually means the event has more rounds than the teams allow. Check the number of rounds, or pair the round manually.",
        round: round
      )

  # The refusal above, past the most rounds the field allows
  # (`PairingsEngine.TeamSwiss.max_rounds/1`): said as what it is - a Swiss
  # cannot pair the same teams again - with the system that can.
  def error_text({:team_pairing, {:too_few_teams, teams, max}, round}),
    do:
      ngettext(
        "Round %{round} can't be paired: a Swiss with %{teams} teams can have at most %{count} round, because teams may not meet twice and after that every team has met every other one. For the teams to play each other again, make the event a round robin (Settings - Options): with two cycles each pair meets twice, colours reversed.",
        "Round %{round} can't be paired: a Swiss with %{teams} teams can have at most %{count} rounds, because teams may not meet twice and after that every team has met every other one. For the teams to play each other again, make the event a round robin (Settings - Options): with two cycles each pair meets twice, colours reversed.",
        max,
        round: round,
        teams: teams
      )

  def error_text({:team_pairing, :no_legal_bye, round}),
    do:
      gettext(
        "Round %{round} can't be paired: every team that could take the bye has already had one or won a match by forfeit, or giving it to them would leave the rest unpairable. This usually means the event has more rounds than the teams allow. Check the number of rounds, or pair the round manually.",
        round: round
      )

  def error_text({:team_pairing, :pairing_crashed, _round}),
    do:
      gettext(
        "Pairing failed unexpectedly. Nothing was changed. Try again; if it keeps happening, report it."
      )

  def error_text({:team_pairing, {:invalid_option, _, _} = reason, round}),
    do:
      gettext("The team pairing for round %{round} failed: %{reason}",
        round: round,
        reason: team_reason_text(reason)
      )

  def error_text({:team_pairing, other, round}),
    do:
      gettext("The team pairing for round %{round} failed: %{reason}",
        round: round,
        reason: team_reason_text(other)
      )

  # The individual (Ainalrami) path's own crash guard
  # (`PairingsEngine.Pairing.run_ainalrami/6`) - same discipline as the team
  # path above: the round is left unpaired, nothing else changed.
  # A postponed-game warning the write path waits on (VCL4THP Q159-168) that
  # arrived unconfirmed - see `PairingsEngine.PostponedGames`. The pages that
  # can trigger one ask first, so this is the fallback for a stale tab.
  def error_text({:needs_acknowledgement, ids}) when is_list(ids),
    do: PairingsEngineWeb.Postponed.needs_acknowledgement_text(ids)

  def error_text(:round_sent_in_trf),
    do:
      gettext(
        "This round's results were finalised and sent in a TRF, so it cannot be unpaired: the games that were sent would have nothing behind them."
      )

  def error_text(:postponed_games_off),
    do:
      gettext(
        "This tournament does not allow postponed games - turn them on under Settings, Scoring first."
      )

  def error_text({:pairing_crashed, _round, nil}),
    do:
      gettext(
        "Pairing failed unexpectedly. Nothing was changed. Try again; if it keeps happening, report it."
      )

  def error_text({:pairing_crashed, _round, category_name}),
    do:
      gettext(
        "Pairing failed unexpectedly for category \"%{category}\". Nothing was changed. Try again; if it keeps happening, report it.",
        category: category_name
      )

  # The engine's own words; tagged so the Pairings page can offer to pair
  # the round by hand (`PairingsEngine.Pairing.create_round_by_hand/1`).
  def error_text({:no_legal_pairing, text}) when is_binary(text), do: text

  def error_text(:not_by_hand),
    do:
      gettext(
        "Only an individual Swiss paired one round at a time can have a round created by hand."
      )

  # A result corrected for the rating report only (C.04.2:4.3) - see
  # `Tournaments.set_rating_correction/3`.
  def error_text(:rating_correction_too_early),
    do:
      gettext(
        "A correction for the rating report only is for a round whose next round is already over. Correct this result the ordinary way."
      )

  def error_text(:not_a_game),
    do: gettext("Only a finished game between two players can be corrected for rating.")

  def error_text(:full_point_bye_unsupported),
    do: gettext("Keizer and team tournaments have no full-point bye.")

  # The engine's slots (`PairingsEngine.EngineSlots`): nothing was paired
  # in any of these, and the button is free to press again.
  def error_text(:engine_already_pairing),
    do:
      gettext(
        "This round is already being paired - from another tab or by a co-arbiter. Wait for that to finish; this page updates when it does."
      )

  def error_text(:engine_busy),
    do:
      gettext(
        "The pairing engine is busy with other tournaments right now. Nothing was paired; try again in a moment."
      )

  def error_text(:engine_timeout),
    do:
      gettext(
        "The pairing took longer than this server allows and was stopped. Nothing was paired. Try again, and if it keeps happening, export the tournament and pair it in the desktop version."
      )

  def error_text(:engine_failed),
    do: gettext("The pairing engine stopped with an error. Nothing was paired.")

  def error_text(reason) when reason in [:tournament_quota, :import_quota],
    do: PairingsEngine.Quotas.message(reason)

  def error_text(:not_found), do: gettext("That is no longer there. Reload the page.")

  def error_text(:invalid_player), do: gettext("That player is not in this tournament.")

  def error_text(:not_in_round), do: gettext("Both players need a seat in the round.")

  def error_text(:same_player), do: gettext("That needs two different players.")

  def error_text(:not_paired), do: gettext("That round is not paired.")

  def error_text(:invalid_paid_status),
    do: gettext("That is not a payment status. Choose paid, not paid or gratis.")

  def error_text(:invalid_range), do: gettext("That range is not valid.")

  def error_text(:invalid_bands), do: gettext("Those bands are not valid. Check the numbers.")

  def error_text(:duplicate_fide_id),
    do: gettext("A player with this FIDE ID is already registered.")

  def error_text(:results_locked),
    do: gettext("Results are locked: they were finalised and sent.")

  def error_text(:invalid_result), do: gettext("That is not a valid result.")

  def error_text(reason) when is_atom(reason) do
    Logger.warning("error_text: no sentence for #{inspect(reason)}")
    gettext("That did not work. Nothing was changed.")
  end

  def error_text(reason) when is_binary(reason), do: reason

  @doc """
  Which page hosts a given `Tournament.missing_setup_fields/1` field - used
  by PlayersLive/PairingsLive to link each specific missing item straight to
  the Settings (sub-)page it lives on, now that Settings is split across
  several pages rather than being one.
  """
  def setup_field_path(tournament, field) when field in [:round_dates],
    do: ~p"/t/#{tournament.id}/settings/dates"

  def setup_field_path(tournament, field) when field in [:chief_arbiter],
    do: ~p"/t/#{tournament.id}/settings/norms"

  def setup_field_path(tournament, field) when field in [:rate_of_play],
    do: ~p"/t/#{tournament.id}/settings/options"

  def setup_field_path(tournament, field) when field in [:fide_tournament_id],
    do: ~p"/t/#{tournament.id}/settings/fide"

  # name, rounds_count, tiebreaks, federation all live on the main
  # Tournament settings page. (start_date, formerly here too, is derived
  # from round_dates now - see Tournament's own doc comment on that
  # field - so it's never a `missing_setup_fields/1` entry on its own.)
  def setup_field_path(tournament, _field), do: ~p"/t/#{tournament.id}/settings"
end
