defmodule PairingsEngineWeb.SettingsSupport do
  @moduledoc """
  Shared helpers and the sub-nav component for the split Settings pages
  (`SettingsTournamentLive`, `SettingsOptionsLive`, `SettingsDatesLive`,
  `SettingsFideLive`, `ExtraPointsLive`) and `CategoriesLive`.

  The old monolithic `SettingsLive` was one ~1900-line page; it's now six
  focused pages sharing:

    * `settings_subnav/1` - the tab strip that lets the user hop between the
      six pages without going back through the top-bar "Settings ▾" menu
      (mirrors `AuditLive.subnav/1`).
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
  @settings_diff_ignore ~w(id status public_slug deleted_at
    manual_ranking_stale fide_compliance_lost_round
    logo_data logo_content_type inserted_at updated_at user_id)a

  @doc """
  Sub-nav shown at the top of every Settings page, so the user can hop
  between the pages without going back through the top-bar "Settings ▾"
  menu. `active` is one of `:tournament`, `:options`, `:results`,
  `:scoring`, `:dates`, `:categories`, `:extra_points`, `:fide`, `:about`,
  `:export`.
  """
  attr :tournament, :map, required: true
  attr :active, :atom, required: true

  def settings_subnav(assigns) do
    ~H"""
    <div class="round-picker" style="flex-wrap: wrap; margin-bottom: 12px">
      <.link
        navigate={~p"/t/#{@tournament.id}/settings"}
        class={["pe-btn", "filter-picker", @active == :tournament && "active"]}
      >
        {gettext("Tournament")}
      </.link>
      <.link
        navigate={~p"/t/#{@tournament.id}/settings/options"}
        class={["pe-btn", "filter-picker", @active == :options && "active"]}
      >
        {gettext("Options")}
      </.link>
      <.link
        navigate={~p"/t/#{@tournament.id}/settings/results"}
        class={["pe-btn", "filter-picker", @active == :results && "active"]}
      >
        {gettext("OpenResults")}
      </.link>
      <.link
        navigate={~p"/t/#{@tournament.id}/settings/scoring"}
        class={["pe-btn", "filter-picker", @active == :scoring && "active"]}
      >
        {gettext("Scoring")}
      </.link>
      <.link
        navigate={~p"/t/#{@tournament.id}/settings/dates"}
        class={["pe-btn", "filter-picker", @active == :dates && "active"]}
      >
        {gettext("Dates")}
      </.link>
      <.link
        navigate={~p"/t/#{@tournament.id}/categories"}
        class={["pe-btn", "filter-picker", @active == :categories && "active"]}
      >
        {gettext("Categories")}
      </.link>
      <.link
        navigate={~p"/t/#{@tournament.id}/settings/extra-points"}
        class={["pe-btn", "filter-picker", @active == :extra_points && "active"]}
      >
        {gettext("Extra points")}
      </.link>
      <.link
        navigate={~p"/t/#{@tournament.id}/settings/fide"}
        class={["pe-btn", "filter-picker", @active == :fide && "active"]}
      >
        FIDE
      </.link>
      <.link
        navigate={~p"/t/#{@tournament.id}/settings/about"}
        class={["pe-btn", "filter-picker", @active == :about && "active"]}
      >
        {gettext("About")}
      </.link>
      <.link
        navigate={~p"/t/#{@tournament.id}/settings/export"}
        class={["pe-btn", "filter-picker", @active == :export && "active"]}
      >
        {gettext("Export")}
      </.link>
    </div>
    """
  end

  @doc """
  A vertical run of settings - the only layout wrapper the Settings pages use.
  Holds `<.setting_field>`s and `<.setting_toggle>`s in DOM order, one per row.
  """
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def setting_group(assigns) do
    ~H"""
    <div class={["set-group", @class]}>{render_slot(@inner_block)}</div>
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
      {render_slot(@inner_block)}
      <span :if={@hint} class="hint">{@hint}</span>
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
  slot :inner_block

  def setting_toggle(assigns) do
    ~H"""
    <label class="set-toggle">
      <input type="hidden" name={@name} value="false" />
      <span class="locked-wrap locked-wrap-inline">
        <input type="checkbox" name={@name} value="true" checked={@checked} disabled={@disabled} />
        <.locked_overlay :if={@field} field={@field} locked?={@locked?} />
      </span>
      <span class="set-toggle-text">
        {@label}
        <span :if={@hint} class="hint">{@hint}</span>
        <.locked_hint_message
          :if={@field}
          field={@field}
          locked_hint={@locked_hint}
          warning={@warning}
        />
        {render_slot(@inner_block)}
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

  def locked_hint_message(assigns) do
    ~H"""
    <div :if={@locked_hint == @field} class="hint locked-hint-msg">
      <p style="margin: 0 0 8px">{@warning}</p>
      <button type="button" class="pe-btn tonal" phx-click="unlock_field" phx-value-field={@field}>
        {gettext("Unlock")}
      </button>
    </div>
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
        "This tournament is set up the way the FIDE pairing rules describe. There is nothing to switch on: that is what a new tournament gets, and only changing a setting can take it away."
      )}
    </p>

    <p
      :if={@show_compliant and @departures == [] and @tournament.fide_compliance_lost_round != nil}
      class="error-note"
    >
      {compliance_lost_line(@tournament.fide_compliance_lost_round)}
      {gettext(
        "The settings match the FIDE rules again, but that is a fact about this tournament's history and it stands."
      )}
    </p>
    """
  end

  # Round 0 is a real value and means "before round 1 was paired" - a Keizer
  # tournament is not FIDE-paired from the moment it is created. "In round 0"
  # would read as a bug, so it gets its own sentence.
  defp compliance_lost_line(0),
    do:
      gettext("Recorded: this stopped matching the FIDE rules before the first round was paired.")

  defp compliance_lost_line(round),
    do: gettext("Recorded: this stopped matching the FIDE rules in round %{round}.", round: round)

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

  # pairing_system and swiss_match_format both live on the Options page.
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
  def error_text(%Ecto.Changeset{} = changeset) do
    Enum.map_join(changeset.errors, ", ", fn {field, {msg, _}} -> "#{field} #{msg}" end)
  end

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

  def error_text(reason) when is_atom(reason),
    do: reason |> to_string() |> String.replace("_", " ")

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
    do: ~p"/t/#{tournament.id}/norms"

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
