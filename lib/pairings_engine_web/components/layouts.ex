defmodule PairingsEngineWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use PairingsEngineWeb, :html

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
      <.link navigate={~p"/"} class="brand">
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
          <path d="M6,17 Q12,20 15,25" fill="none" stroke="#1c1a15" stroke-width="1.6" stroke-linecap="round" opacity="0.55" />
          <path d="M58,18 Q52,21 49,26" fill="none" stroke="#1c1a15" stroke-width="1.6" stroke-linecap="round" opacity="0.55" />
          <circle cx="32" cy="24" r="14" fill="url(#bm-orb)" stroke="#1c1a15" stroke-width="3" />
          <ellipse cx="27" cy="18" rx="4" ry="6" fill="#ffffff" opacity="0.5" transform="rotate(-25 27 18)" />
        </svg>
        <span class="brand-name">Open<strong>Pairings</strong></span>
      </.link>
      <nav>
        <.link navigate={~p"/"} class={tab_class(@active == "tournaments")}>Tournaments</.link>
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
          <.link navigate={~p"/t/#{@tournament.id}/norms"} class={tab_class(@active == "norms")}>
            Norms
          </.link>
          <.link navigate={~p"/t/#{@tournament.id}/audit"} class={tab_class(@active == "audit")}>
            Audit
          </.link>
          <.link navigate={~p"/t/#{@tournament.id}/settings"} class={tab_class(@active == "settings")}>
            Settings
          </.link>
          <.link
            :if={@tournament.categories_enabled}
            navigate={~p"/t/#{@tournament.id}/categories"}
            class={tab_class(@active == "categories")}
          >
            Categories
          </.link>
        <% end %>
        <.link
          :if={!@tournament}
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
      </nav>
      <nav class="topbar-auth">
        <%= if @current_scope do %>
          <span class="user-email">{@current_scope.user.email}</span>
          <.link navigate={~p"/users/settings"}>Settings</.link>
          <.link href={~p"/users/log-out"} method="delete">Log out</.link>
        <% else %>
          <.link navigate={~p"/users/log-in"}>Log in</.link>
          <.link navigate={~p"/users/register"}>Register</.link>
        <% end %>
        <span class="app-version">v{app_version()}</span>
      </nav>
    </header>

    <main class="page">
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
    """
  end

  defp tab_class(true), do: "active"
  defp tab_class(false), do: nil

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

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
