defmodule PairingsEngineWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use PairingsEngineWeb, :html

  import PairingsEngineWeb.Components.ConnectionStatus, only: [publish_pill: 1]

  alias PairingsEngine.Authz
  alias PairingsEngine.Build
  alias PairingsEngine.Publishing.Monitor

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

      <Layouts.app publish_status={assigns[:publish_status]} flash={@flash} current_path={assigns[:current_path]}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :tournament, :map, default: nil, doc: "current tournament, enables its tabs"
  attr :active, :string, default: nil, doc: "active tab key"

  attr :current_path, :string,
    default: nil,
    doc:
      "the path the visitor is on, so the language picker can return them to it. " <>
        "Assigned by PairingsEngineWeb.LocaleHook and forwarded by each caller - a " <>
        "function component only sees what it is passed, which is why it must be " <>
        "threaded rather than read from the socket."

  attr :publish_status, :any,
    default: nil,
    doc:
      "from `PairingsEngineWeb.PublishStatusHook`. Threaded rather than read here " <>
        "because a function component only sees what it is passed - and LiveView only " <>
        "re-invokes it when one of those attributes changes, so a global read would " <>
        "paint once and then never move, showing \"Live\" straight through an outage."

  slot :inner_block, required: true

  def app(assigns) do
    # A page that forgets the attribute gets the cached value rather than a
    # permanent "Checking…". It will not update live there, which is a
    # missing feature; a pill frozen on the wrong word would be a lie.
    assigns =
      case assigns.publish_status do
        nil -> assign(assigns, :publish_status, Monitor.status())
        _ -> assigns
      end

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
            {gettext("Players")}
          </.link>
          <.link navigate={~p"/t/#{@tournament.id}/pairings"} class={tab_class(@active == "pairings")}>
            {gettext("Pairings")}
          </.link>
          <.link
            navigate={~p"/t/#{@tournament.id}/standings"}
            class={tab_class(@active == "standings")}
          >
            {gettext("Standings")}
          </.link>
          <.link navigate={~p"/t/#{@tournament.id}/print"} class={tab_class(@active == "print")}>
            {gettext("Print")}
          </.link>
          <details class="topbar-menu" name="topbar-popover">
            <summary class={tab_class(@active in ["audit", "norms"])}>{gettext("Advanced")}</summary>
            <div class="topbar-menu-panel">
              <.link navigate={~p"/t/#{@tournament.id}/norms"} class="topbar-menu-item">
                {gettext("Norms")}
              </.link>
              <.link navigate={~p"/t/#{@tournament.id}/history"} class="topbar-menu-item">
                {gettext("History")}
              </.link>
              <.link navigate={~p"/t/#{@tournament.id}/audit"} class="topbar-menu-item">
                {gettext("Audit trail")}
              </.link>
              <.link navigate={~p"/t/#{@tournament.id}/audit/explain"} class="topbar-menu-item">
                {gettext("Pairing rationale")}
              </.link>
            </div>
          </details>
          <details class="topbar-menu" name="topbar-popover">
            <summary class={tab_class(@active in ["settings", "categories"])}>
              {gettext("Settings")}
            </summary>
            <div class="topbar-menu-panel">
              <.link navigate={~p"/t/#{@tournament.id}/settings"} class="topbar-menu-item">
                {gettext("Tournament")}
              </.link>
              <.link navigate={~p"/t/#{@tournament.id}/settings/options"} class="topbar-menu-item">
                {gettext("Options")}
              </.link>
              <.link navigate={~p"/t/#{@tournament.id}/settings/scoring"} class="topbar-menu-item">
                {gettext("Scoring")}
              </.link>
              <.link navigate={~p"/t/#{@tournament.id}/settings/dates"} class="topbar-menu-item">
                {gettext("Dates")}
              </.link>
              <.link navigate={~p"/t/#{@tournament.id}/categories"} class="topbar-menu-item">
                {gettext("Categories")}
              </.link>
              <.link
                navigate={~p"/t/#{@tournament.id}/settings/extra-points"}
                class="topbar-menu-item"
              >
                {gettext("Extra points")}
              </.link>
              <.link navigate={~p"/t/#{@tournament.id}/settings/fide"} class="topbar-menu-item">
                FIDE
              </.link>
            </div>
          </details>
        <% end %>
        <%!-- Hidden, not merely disabled. Gating the buttons on Connections
              left the page readable by any account, and what it shows - the
              publishing address, the backup filenames, the sync state - is
              the operator's business. The route refuses too
              (`PairingsEngineWeb.RequireRole`); this stops offering a link
              that would only bounce. --%>
        <.link
          :if={!@tournament && @current_scope && Authz.may_support?(@current_scope.user)}
          navigate={~p"/fide"}
          class={tab_class(@active == "fide")}
        >
          {gettext("Connections")}
        </.link>
        <.link
          :if={!@tournament && @current_scope && Authz.may_administer?(@current_scope.user)}
          navigate={~p"/admin"}
          class={tab_class(@active == "admin")}
        >
          {gettext("Admin")}
        </.link>
        <.link
          :if={!@tournament}
          navigate={~p"/tools/norms"}
          class={tab_class(@active == "tools")}
        >
          {gettext("Tools")}
        </.link>
        <.link
          :if={!@tournament && @current_scope}
          navigate={~p"/changelog"}
          class={tab_class(@active == "changelog")}
        >
          {gettext("Changelog")}
        </.link>
      </nav>
      <nav class="topbar-auth">
        <.accent_picker />
        <.language_picker locale={assigns[:locale]} path={assigns[:current_path] || "/"} />
        <.theme_switch />
        <%= if @current_scope do %>
          <%!-- Read here rather than passed in. `Layouts.app` is a function
                component, so it sees only the attributes its caller hands it -
                and there are 29 callers, which makes "pass it everywhere" a
                thing somebody forgets on the thirtieth page.

                The read is an `:ets` lookup: no process call, so it cannot
                queue behind the fifteen-second network check it reports on.
                `PairingsEngineWeb.PublishStatusHook` is what makes it move -
                it subscribes and re-assigns, and the re-render comes back
                through here. --%>
          <.publish_pill status={@publish_status} />
          <span class="user-email">{@current_scope.user.email}</span>
          <%!-- Hidden on a local install for the same reason the log-out
                link below is: the page offers change-email and
                change-password for an account nobody logs into, and its
                change-email confirmation would be sent to `ConsoleMailer`,
                i.e. to a terminal the arbiter is probably not watching. A
                control that visibly does nothing is worse than no
                control. --%>
          <.link :if={!Authz.local_mode?()} navigate={~p"/users/settings"}>
            {gettext("Settings")}
          </.link>
          <%!-- Shown on a local install too, unlike the account settings link
                above. The national-federation switches are the one account
                preference an arbiter running the binary on their own laptop
                genuinely needs - "I am not in Belgium, take those buttons
                away" - and there is nothing on that page to confirm by
                email or to sign in for. --%>
          <.link navigate={~p"/users/features"} class={tab_class(@active == "features")}>
            {gettext("Features")}
          </.link>
          <%!-- No log out on a local install. There is no second account to
                log in as, and the next request would sign the same owner
                straight back in - a control that visibly does nothing is
                worse than no control. See
                `PairingsEngineWeb.UserAuth.local_owner_session/2`. --%>
          <.link :if={!local_mode?()} href={~p"/users/log-out"} method="delete">
            {gettext("Log out")}
          </.link>
        <% else %>
          <.link navigate={~p"/users/log-in"} class="topbar-signin">{gettext("Log in")}</.link>
        <% end %>
        <%!-- The BUILD, not just the release. Two deploys a week apart both
              said "v0.18.0", so the one question asked after every deploy -
              is the thing I just pushed the thing that is running - had no
              answer on the screen. The full identifier, with the commit and
              the build time, is in the tooltip. --%>
        <.link navigate={~p"/changelog"} class="app-version" title={Build.long()}>
          v{Build.id()}
        </.link>
      </nav>
    </header>

    <main class="page">
      <%!-- Rendered in the layout rather than per-page so it cannot be
            forgotten on one: every authenticated tournament page goes through
            here, so archiving is visible on all of them at once. --%>
      <div :if={@tournament && @tournament.archived_at} class="archived-banner">
        <span>
          <strong>{gettext("This tournament is archived.")}</strong>
          {gettext(
            "It's read-only - every change is refused until you unarchive it. Everything else (viewing, printing, exporting, its public link) still works normally."
          )}
        </span>
        <.link navigate={~p"/"} class="pe-btn">{gettext("Unarchive from Tournaments")}</.link>
      </div>

      <%!-- The sibling of the archive banner, for the other reason a
            tournament is read-only: it has been handed off, and is live on
            some other machine right now. Same markup and the same
            `.archived-banner` class deliberately - both say "this is a
            state, not a failure, and every change here is refused", and a
            second visual language for the same message would only make the
            two harder to tell apart at a glance.

            The button is not the counterpart of "Unarchive", and must not
            read like one. Unarchiving is something this copy can simply do;
            taking a tournament back requires a file from the machine that
            has it, so this leads to the one place in the app that can take a
            file - the Tournaments page, which already holds every other
            import - rather than promising to unlock anything on its own. The
            banner is where an arbiter finds out they need the file; `?return`
            is what opens the box that wants it. --%>
      <div :if={@tournament && @tournament.handed_off_at} class="archived-banner">
        <span>
          <strong>
            {gettext("This tournament has been handed off to %{place}.",
              place: handoff_destination(@tournament.handed_off_to)
            )}
          </strong>
          {gettext(
            "It left this copy on %{at}, and is live there now. It's read-only here - every change is refused until it's handed back, and the returning file brings everything played over there with it. Everything else (viewing, printing, exporting) still works normally.",
            at: handoff_time(@tournament.handed_off_at)
          )}
        </span>
        <.link navigate={~p"/?return=#{@tournament.id}"} class="pe-btn primary">
          {gettext("Bring it back")}
        </.link>
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

  defp tab_class(true), do: "active"
  defp tab_class(false), do: nil

  # Where a handed-off tournament went. The label is free text an arbiter
  # typed, so it can be blank or missing (a hand-off recorded by an older
  # build, a payload that carried no name) - and a sentence that trails off
  # into nothing reads as a bug, where a vague one at least still parses.
  defp handoff_destination(label) when is_binary(label) do
    case String.trim(label) do
      "" -> gettext("another copy")
      trimmed -> trimmed
    end
  end

  defp handoff_destination(_), do: gettext("another copy")

  # Same format as every other timestamp shown to an arbiter (snapshots,
  # registrations, round publication) - explicitly UTC, because the machine
  # holding the tournament is quite possibly in another timezone.
  defp handoff_time(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  # Whether this is a single-user local install (`OPENPAIRINGS_LOCAL=1`).
  # False everywhere else, including every server deployment.
  defp local_mode?, do: PairingsEngine.Authz.local_mode?()

  @doc """
  The running application's version string, e.g. "0.18.0".

  Delegates to `PairingsEngine.Build`, which is the one place that knows what
  build this is. This function used to read `Application.spec/2` itself, and
  so did `PairingsEngine.Snapshot` and `PairingsEngine.TrfExport` - three
  copies of four lines, one of which carried a comment explaining that it was
  duplicated on purpose.
  """
  def app_version, do: Build.version()

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
    {"rose", "#be123c", "Rose"},
    {"slate", "#475569", "Slate"},
    {"indigo", "#4338ca", "Indigo"},
    {"cyan", "#0e7490", "Cyan"},
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
      <summary
        class="accent-picker-trigger"
        title={gettext("Accent colour")}
        aria-label={gettext("Accent colour")}
      >
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
    {"slate", "hero-window-micro", "Slate"},
    {"mocha", "hero-heart-micro", "Mocha"},
    {"paper", "hero-document-micro", "Paper"},
    {"board", "hero-squares-2x2-micro", "Board"},
    {"contrast", "hero-eye-micro", "High Contrast"}
  ]

  attr :locale, :string, default: nil
  attr :path, :string, default: "/"

  @doc """
  Language picker.

  Links rather than buttons, because switching language is a GET that
  changes a session value and comes back - there is no form here to submit
  and no LiveView event that could write a session anyway.

  Rendered only when there is more than one language to choose. A picker
  offering a single option is furniture: it takes space in the top bar,
  invites a click and does nothing. It appears by itself the day a second
  catalogue lands, which is the point of building this now.
  """
  def language_picker(assigns) do
    assigns = assign(assigns, :locales, PairingsEngineWeb.Locale.locales())

    ~H"""
    <details :if={length(@locales) > 1} class="theme-picker" name="topbar-popover">
      <summary
        class="theme-picker-trigger"
        title={gettext("Language")}
        aria-label={gettext("Language")}
      >
        <.icon name="hero-language-micro" class="size-4" />
      </summary>
      <div class="theme-picker-panel" role="group" aria-label={gettext("Language")}>
        <a
          :for={{code, name} <- @locales}
          href={~p"/locale/#{code}?redirect_to=#{@path}"}
          class={["theme-picker-item", code == @locale && "is-current"]}
        >
          {name}
        </a>
      </div>
    </details>
    """
  end

  @doc """
  A compact theme switch (System / Light / Dark / Slate / Mocha / Paper /
  Board / High Contrast) for the top bar,
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
      <summary
        class="theme-picker-trigger"
        title={gettext("Colour theme")}
        aria-label={gettext("Colour theme")}
      >
        <.icon name="hero-swatch-micro" class="size-4" />
      </summary>
      <div class="theme-picker-panel" role="group" aria-label={gettext("Colour theme")}>
        <button
          type="button"
          class="theme-picker-item"
          data-theme-opt="system"
          data-phx-theme="system"
          phx-click={JS.dispatch("phx:set-theme")}
        >
          <.icon name="hero-computer-desktop-micro" class="size-4" /> {gettext("System")}
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
