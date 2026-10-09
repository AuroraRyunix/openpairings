defmodule PairingsEngineWeb.Components.GroupSwitcher do
  @moduledoc """
  The "Open | U20 | U12" strip at the top of every page of a tournament that
  belongs to an event (`PairingsEngine.TournamentGroups`).

  Rendered by `PairingsEngineWeb.Layouts.app/1`, so no page can forget it.
  Each sibling links to the page the arbiter is on - Standings to Standings,
  Players to Players - and to the sibling's Players page when that page does
  not exist there (a team page for an individual tournament, a particular
  round's explanation, a match). Shows only the siblings the viewer may open,
  because `TournamentGroups.switcher/2` only returns those, and nothing at
  all when that leaves just the tournament they are already in.

  Segmented on a wide screen; one `<details>` dropdown on a phone, where five
  labels in a row would only scroll sideways. Both are plain links: no
  JavaScript, and nothing for a LiveView to handle.
  """
  use PairingsEngineWeb, :html

  alias PairingsEngine.Tournaments.Tournament

  # Pages every tournament has, sibling or not: kept as they are.
  @portable ~w(players pairings standings print history audit audit/explain postponed
               registrations live norms categories settings settings/options
               settings/restrictions settings/results settings/scoring settings/dates
               settings/extra-points settings/fide settings/about settings/export
               settings/changelog)

  attr :switcher, :any, required: true, doc: "from `TournamentGroups.switcher/2`, or nil"
  attr :current_path, :string, default: nil

  def group_switcher(assigns) do
    assigns =
      assign(assigns, :members, (assigns.switcher && assigns.switcher.members) || [])

    ~H"""
    <nav
      :if={length(@members) > 1}
      id="group-switcher"
      class="group-switcher"
      aria-label={gettext("Tournaments in %{event}", event: @switcher.group.name)}
    >
      <span class="group-switcher-name">{@switcher.group.name}</span>

      <ul class="group-switcher-segments">
        <li :for={m <- @members}>
          <.link
            id={"group-switch-#{m.id}"}
            navigate={sibling_path(@current_path, m)}
            class={["group-switcher-item", m.current? && "current"]}
            aria-current={m.current? && "page"}
            title={m.name}
          >
            {m.label}
          </.link>
        </li>
      </ul>

      <details class="group-switcher-menu" id="group-switcher-menu">
        <summary>
          <span class="group-switcher-menu-current">{current_label(@members)}</span>
          <.icon name="hero-chevron-down" class="size-4" />
        </summary>
        <div class="group-switcher-menu-panel">
          <.link
            :for={m <- @members}
            id={"group-menu-#{m.id}"}
            navigate={sibling_path(@current_path, m)}
            class={["group-switcher-menu-item", m.current? && "current"]}
            aria-current={m.current? && "page"}
          >
            {m.label}
          </.link>
        </div>
      </details>
    </nav>
    """
  end

  defp current_label(members) do
    case Enum.find(members, & &1.current?) do
      nil -> ""
      m -> m.label
    end
  end

  @doc """
  Where the switcher sends the viewer for `sibling`: the same page of it as
  `current_path` is of the current tournament, when the sibling has that
  page; its Players page otherwise.
  """
  def sibling_path(current_path, %{id: id} = sibling) do
    case sub_page(current_path) do
      nil -> "/t/#{id}/players"
      rest -> "/t/#{id}/" <> portable(rest, sibling)
    end
  end

  # "/t/12/settings/fide?x=1" -> "settings/fide"
  defp sub_page(path) when is_binary(path) do
    path = path |> String.split("?", parts: 2) |> hd()

    case String.split(path, "/", parts: 4) do
      ["", "t", _id, rest] when rest != "" -> String.trim_trailing(rest, "/")
      _ -> nil
    end
  end

  defp sub_page(_), do: nil

  defp portable(rest, sibling) do
    cond do
      rest in @portable ->
        rest

      # A round's explanation or one match: rounds are not shared between
      # tournaments, so the round number would mean nothing over there.
      String.starts_with?(rest, "pairings/") ->
        "pairings"

      rest == "teams" or rest == "team-sheets" or String.starts_with?(rest, "team-sheets/") ->
        if Tournament.team?(sibling), do: rest, else: "players"

      true ->
        "players"
    end
  end
end
