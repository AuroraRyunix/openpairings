defmodule PairingsEngineWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use PairingsEngineWeb, :html

  alias PairingsEngine.Fide
  alias PairingsEngine.Kbsb

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :tournament, :map, default: nil, doc: "current tournament, enables its tabs"
  attr :active, :string, default: nil, doc: "active tab key"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="topbar">
      <.link navigate={if(@current_scope, do: ~p"/", else: ~p"/users/log-in")} class="brand">
        <.brand_mark />
        <span class="brand-name">Open<strong>Pairings</strong></span>
      </.link>
      <nav>
        <.link navigate={~p"/"} class={tab_class(@active == "tournaments")}>
          {if @tournament, do: "Home", else: "Tournaments"}
        </.link>
        <%= if @tournament do %>
          <.link navigate={~p"/t/#{@tournament.id}/players"} class={tab_class(@active == "players")}>
            Players
          </.link>
          <.link navigate={~p"/t/#{@tournament.id}/pairings"} class={tab_class(@active == "pairings")}>
            Pairings
          </.link>
          <.link
            navigate={~p"/t/#{@tournament.id}/standings"}
            class={tab_class(@active == "standings")}
          >
            Standings
          </.link>
          <.link navigate={~p"/t/#{@tournament.id}/print"} class={tab_class(@active == "print")}>
            Print
          </.link>
          <details class="topbar-menu" name="topbar-popover">
            <summary class={tab_class(@active in ["audit", "norms"])}>Advanced</summary>
            <div class="topbar-menu-panel">
              <.link navigate={~p"/t/#{@tournament.id}/norms"} class="topbar-menu-item">
                Norms
              </.link>
              <.link navigate={~p"/t/#{@tournament.id}/history"} class="topbar-menu-item">
                History
              </.link>
              <.link navigate={~p"/t/#{@tournament.id}/audit"} class="topbar-menu-item">
                Audit trail
              </.link>
              <.link navigate={~p"/t/#{@tournament.id}/audit/explain"} class="topbar-menu-item">
                Pairing rationale
              </.link>
            </div>
          </details>
          <details class="topbar-menu" name="topbar-popover">
            <summary class={tab_class(@active in ["settings", "categories"])}>Settings</summary>
            <div class="topbar-menu-panel">
              <.link navigate={~p"/t/#{@tournament.id}/settings"} class="topbar-menu-item">
                Tournament
              </.link>
              <.link navigate={~p"/t/#{@tournament.id}/settings/options"} class="topbar-menu-item">
                Options
              </.link>
              <.link navigate={~p"/t/#{@tournament.id}/settings/scoring"} class="topbar-menu-item">
                Scoring
              </.link>
              <.link navigate={~p"/t/#{@tournament.id}/settings/dates"} class="topbar-menu-item">
                Dates
              </.link>
              <.link navigate={~p"/t/#{@tournament.id}/categories"} class="topbar-menu-item">
                Categories
              </.link>
              <.link
                navigate={~p"/t/#{@tournament.id}/settings/extra-points"}
                class="topbar-menu-item"
              >
                Extra points
              </.link>
              <.link navigate={~p"/t/#{@tournament.id}/settings/fide"} class="topbar-menu-item">
                FIDE
              </.link>
            </div>
          </details>
        <% end %>
        <.link
          :if={!@tournament && @current_scope}
          navigate={~p"/fide"}
          class={tab_class(@active == "fide")}
        >
          Rating lists
        </.link>
        <.link
          :if={!@tournament}
          navigate={~p"/tools/norms"}
          class={tab_class(@active == "tools")}
        >
          Tools
        </.link>
        <.link
          :if={!@tournament && @current_scope}
          navigate={~p"/changelog"}
          class={tab_class(@active == "changelog")}
        >
          Changelog
        </.link>
      </nav>
      <nav class="topbar-auth">
        <.accent_picker />
        <.theme_switch />
        <%= if @current_scope do %>
          <span class="sync-freshness" title="Local FIDE / KBSB rating-list sync status">
            FIDE: {sync_label(Fide.last_sync())} · KBSB: {sync_label(Kbsb.last_sync())}
          </span>
          <span class="user-email">{@current_scope.user.email}</span>
          <.link navigate={~p"/users/settings"}>Settings</.link>
          <.link href={~p"/users/log-out"} method="delete">Log out</.link>
        <% else %>
          <.link navigate={~p"/users/log-in"} class="topbar-signin">Log in</.link>
        <% end %>
        <span class="app-version">v{app_version()}</span>
      </nav>
    </header>

    <main class="page">
      <%!-- Rendered in the layout rather than per-page so it cannot be
            forgotten on one: every authenticated tournament page goes through
            here, so archiving is visible on all of them at once. --%>
      <div :if={@tournament && @tournament.archived_at} class="archived-banner">
        <span>
          <strong>This tournament is archived.</strong>
          It's read-only - every change is refused until you unarchive it. Everything else
          (viewing, printing, exporting, its public link) still works normally.
        </span>
        <.link navigate={~p"/"} class="pe-btn">Unarchive from Tournaments</.link>
      </div>

      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc false
  def brand_mark(assigns) do
    ~H"""
    <svg class="brand-mark" viewBox="0 0 64 48" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
      <defs>
        <linearGradient id="bm-orb" x1="0%" y1="0%" x2="100%" y2="100%">
          <stop offset="0%" stop-color="#3d7458" />
          <stop offset="100%" stop-color="#24503a" />
        </linearGradient>
      </defs>
      <path
        d="M22,18 Q10,10 1,14 Q8,22 10,30 Q16,32 22,30 Q26,26 22,18 Z"
        fill="#f7f3e8"
        stroke="#1c1a15"
        stroke-width="3"
        stroke-linejoin="round"
      />
      <path
        d="M42,18 Q54,10 63,14 Q56,22 54,30 Q48,32 42,30 Q38,26 42,18 Z"
        fill="#f7f3e8"
        stroke="#1c1a15"
        stroke-width="3"
        stroke-linejoin="round"
      />
      <path
        d="M6,17 Q12,20 15,25"
        fill="none"
        stroke="#1c1a15"
        stroke-width="1.6"
        stroke-linecap="round"
        opacity="0.55"
      />
      <path
        d="M58,18 Q52,21 49,26"
        fill="none"
        stroke="#1c1a15"
        stroke-width="1.6"
        stroke-linecap="round"
        opacity="0.55"
      />
      <circle cx="32" cy="24" r="14" fill="url(#bm-orb)" stroke="#1c1a15" stroke-width="3" />
      <ellipse
        cx="27"
        cy="18"
        rx="4"
        ry="6"
        fill="#ffffff"
        opacity="0.5"
        transform="rotate(-25 27 18)"
      />
    </svg>
    """
  end

  @doc """
  Minimal layout for the public (no-login) tournament pages
  (`PairingsEngineWeb.PublicStandingsLive` / `PublicPairingsLive` - see
  docs/public-pages.md). Deliberately *not* `app/1`: a spectator who scanned
  a QR code to check standings has no use for the authenticated topbar's
  tournament tabs, accent picker, or sign-in/settings links - this is just
  the brand mark and the theme switch (still useful: a bright phone screen
  in a dim tournament hall is exactly the scenario `Layouts.theme_switch/1`
  exists for), then the page content.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  slot :inner_block, required: true

  def public(assigns) do
    ~H"""
    <header class="topbar public-topbar">
      <.link navigate={~p"/"} class="brand">
        <.brand_mark />
        <span class="brand-name">Open<strong>Pairings</strong></span>
      </.link>
      <div class="topbar-auth">
        <.theme_switch />
      </div>
    </header>

    <main class="page">
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
    """
  end

  defp tab_class(true), do: "active"
  defp tab_class(false), do: nil

  @doc false
  # Compact "how stale is this rating list" label for the top-bar freshness
  # strip, e.g. "3 days ago" / "just now" / "never synced". `last_sync/0`
  # returns the raw `datetime('now')` string stored in the `meta` table
  # (UTC, "YYYY-MM-DD HH:MM:SS", no "T") or nil if the list has never synced.
  def sync_label(nil), do: "never synced"

  def sync_label(timestamp) when is_binary(timestamp) do
    case NaiveDateTime.from_iso8601(String.replace(timestamp, " ", "T", global: false)) do
      {:ok, synced_at} -> relative_time(synced_at)
      {:error, _} -> timestamp
    end
  end

  defp relative_time(%NaiveDateTime{} = synced_at) do
    diff = NaiveDateTime.diff(NaiveDateTime.utc_now(), synced_at, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> pluralize(div(diff, 60), "minute") <> " ago"
      diff < 86_400 -> pluralize(div(diff, 3600), "hour") <> " ago"
      diff < 2_592_000 -> pluralize(div(diff, 86_400), "day") <> " ago"
      true -> "over a month ago"
    end
  end

  defp pluralize(1, unit), do: "1 #{unit}"
  defp pluralize(n, unit), do: "#{n} #{unit}s"

  @doc """
  Returns the running application's version string (from mix.exs `version:`),
  e.g. "0.9.0". Works in dev and in `MIX_ENV=prod mix phx.server` alike.
  """
  def app_version do
    case Application.spec(:pairings_engine, :vsn) do
      vsn when is_list(vsn) -> List.to_string(vsn)
      vsn when is_binary(vsn) -> vsn
      _ -> "0.0.0"
    end
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  # Accent choices shown in the picker: {key, swatch colour, label}.
  @accents [
    {"green", "#2e5e44", "Green"},
    {"blue", "#2563eb", "Blue"},
    {"teal", "#0d7d74", "Teal"},
    {"violet", "#7c3aed", "Violet"},
    {"amber", "#b45309", "Amber"},
    {"rose", "#be123c", "Rose"},
    {"slate", "#475569", "Slate"},
    {"indigo", "#4338ca", "Indigo"},
    {"cyan", "#0e7490", "Cyan"},
    {"orange", "#c2410c", "Orange"},
    {"fuchsia", "#a21caf", "Fuchsia"}
  ]

  @doc """
  Accent-colour picker for the top bar - a palette popover of swatches,
  independent of the light/dark theme. Applied client-side via `data-accent`
  on `<html>` (see the inline script in root.html.heex), so it needs no server
  state and persists across reloads and tabs.
  """
  def accent_picker(assigns) do
    assigns = assign(assigns, :accents, @accents)

    ~H"""
    <details class="accent-picker" name="topbar-popover">
      <summary class="accent-picker-trigger" title="Accent colour" aria-label="Accent colour">
        <span class="accent-picker-current"></span>
      </summary>
      <div class="accent-picker-panel">
        <button
          :for={{key, color, label} <- @accents}
          type="button"
          class="accent-swatch"
          data-accent-opt={key}
          data-phx-accent={key}
          phx-click={JS.dispatch("phx:set-accent")}
          style={"--swatch: #{color}"}
          title={label}
          aria-label={label}
        ></button>
      </div>
    </details>
    """
  end

  # Theme choices shown in the picker: {key, icon, label}. "system" is
  # special-cased in the template (it has no fixed swatch colour, since it
  # resolves to whichever of light/dark the OS is in) - everything after it
  # is a real, named palette with its own `[data-theme="key"]` block in
  # app.css. Order here is display order in the popover.
  @themes [
    {"light", "hero-sun-micro", "Light"},
    {"dark", "hero-moon-micro", "Dark"},
    {"solarized", "hero-sparkles-micro", "Solarized Dark"},
    {"nord", "hero-cloud-micro", "Nord"},
    {"dracula", "hero-bolt-micro", "Dracula"},
    {"catppuccin", "hero-heart-micro", "Catppuccin Mocha"},
    {"gruvbox", "hero-fire-micro", "Gruvbox Dark"}
  ]

  @doc """
  A compact theme switch (System / Light / Dark / Solarized Dark / Nord /
  Dracula / Catppuccin Mocha / Gruvbox Dark) for the top bar,
  styled with the app's own design tokens so it matches the rest of the UI in
  both themes. The active option is highlighted purely from CSS, keyed off the
  `data-theme` / `data-theme-source` attributes the inline script in
  root.html.heex maintains on `<html>` - so it needs no server state and
  reflects the choice instantly, even across tabs.
  """
  def theme_switch(assigns) do
    assigns = assign(assigns, :themes, @themes)

    ~H"""
    <details class="theme-picker" name="topbar-popover">
      <summary class="theme-picker-trigger" title="Colour theme" aria-label="Colour theme">
        <.icon name="hero-swatch-micro" class="size-4" />
      </summary>
      <div class="theme-picker-panel" role="group" aria-label="Colour theme">
        <button
          type="button"
          class="theme-picker-item"
          data-theme-opt="system"
          data-phx-theme="system"
          phx-click={JS.dispatch("phx:set-theme")}
        >
          <.icon name="hero-computer-desktop-micro" class="size-4" /> System
        </button>
        <button
          :for={{key, icon, label} <- @themes}
          type="button"
          class="theme-picker-item"
          data-theme-opt={key}
          data-phx-theme={key}
          phx-click={JS.dispatch("phx:set-theme")}
        >
          <.icon name={icon} class="size-4" /> {label}
        </button>
      </div>
    </details>
    """
  end
end
