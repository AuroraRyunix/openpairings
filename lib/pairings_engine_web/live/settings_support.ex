defmodule PairingsEngineWeb.SettingsSupport do
  @moduledoc """
  Shared helpers and the sub-nav component for the split Settings pages
  (`SettingsTournamentLive`, `SettingsOptionsLive`, `SettingsDatesLive`,
  `SettingsFideLive`, `ExtraPointsLive`) and `CategoriesLive`.

  The old monolithic `SettingsLive` was one ~1900-line page; it's now six
  focused pages sharing:

    * `settings_subnav/1` — the tab strip that lets the user hop between the
      six pages without going back through the top-bar "Settings ▾" menu
      (mirrors `AuditLive.subnav/1`).
    * the dirty/stale tracker mechanism — each page whose form renders its
      inputs' `value` straight from `@tournament` must not blindly reload
      `@tournament` on every PubSub broadcast (that would reset text the user
      is mid-typing). `attach_dirty_tracker/1` flips `dirty` the moment any
      event fires; `handle_stale_check/1` only flags the page `stale` when a
      freshly-loaded row actually differs from what's assigned.
    * `log_settings_change/3` / `tournament_diff/2` — the before/after audit
      diff written on every settings save.
    * `error_text/1` — changeset error formatting.
  """
  use PairingsEngineWeb, :html

  import Phoenix.LiveView, only: [attach_hook: 4]

  alias PairingsEngine.{Audit, Tournaments}
  alias PairingsEngine.Tournaments.Tournament

  # Tournament fields excluded from the settings audit diff — derived,
  # internal or noisy (binary logo blob, PubSub-recomputed status/flags,
  # timestamps, ownership). Everything else is diffed field-by-field.
  @settings_diff_ignore ~w(id status public_slug deleted_at manual_ranking_stale
    logo_data logo_content_type inserted_at updated_at user_id)a

  @doc """
  Sub-nav shown at the top of every Settings page, so the user can hop
  between the six pages without going back through the top-bar "Settings ▾"
  menu. `active` is one of `:tournament`, `:options`, `:dates`,
  `:categories`, `:extra_points`, `:fide`.
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
        Tournament
      </.link>
      <.link
        navigate={~p"/t/#{@tournament.id}/settings/options"}
        class={["pe-btn", "filter-picker", @active == :options && "active"]}
      >
        Options
      </.link>
      <.link
        navigate={~p"/t/#{@tournament.id}/settings/dates"}
        class={["pe-btn", "filter-picker", @active == :dates && "active"]}
      >
        Dates
      </.link>
      <.link
        navigate={~p"/t/#{@tournament.id}/categories"}
        class={["pe-btn", "filter-picker", @active == :categories && "active"]}
      >
        Categories
      </.link>
      <.link
        navigate={~p"/t/#{@tournament.id}/settings/extra-points"}
        class={["pe-btn", "filter-picker", @active == :extra_points && "active"]}
      >
        Extra points
      </.link>
      <.link
        navigate={~p"/t/#{@tournament.id}/settings/fide"}
        class={["pe-btn", "filter-picker", @active == :fide && "active"]}
      >
        FIDE
      </.link>
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
      This tournament was updated elsewhere while you were editing. Saving will overwrite that
      change with what's on this page — reload the page first if you want to see it instead.
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
  second-level precision) — a broadcast could just be the echo of our own
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
  diff of only the fields that actually changed — a no-op when nothing
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

  @doc "Field-by-field diff of two tournament structs, skipping derived/internal fields."
  def tournament_diff(before, after_tournament) do
    fields = Tournament.__schema__(:fields) -- @settings_diff_ignore

    for field <- fields,
        Map.get(before, field) != Map.get(after_tournament, field),
        into: %{} do
      {to_string(field), [Map.get(before, field), Map.get(after_tournament, field)]}
    end
  end

  @doc "Human-readable changeset error string."
  def error_text(changeset) do
    Enum.map_join(changeset.errors, ", ", fn {field, {msg, _}} -> "#{field} #{msg}" end)
  end

  @doc """
  Which page hosts a given `Tournament.missing_setup_fields/1` field — used
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

  # name, start_date, rounds_count, tiebreaks, federation all live on the
  # main Tournament settings page.
  def setup_field_path(tournament, _field), do: ~p"/t/#{tournament.id}/settings"
end
