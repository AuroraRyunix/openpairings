defmodule PairingsEngine.Plugins do
  @moduledoc """
  The plugins compiled into this build, and the one place the core calls
  them from. See `PairingsEngine.Plugin` for the contract and for how a
  plugin gets into a build at all.

  With no plugin configured - every build but the hosted one - each
  function here answers as if the hook did not exist: no routes, no menu
  entries, no features, roster board order, no findings, no candidates.
  The core calls these unconditionally and needs no other check.

  A plugin that raises inside a hook is a plugin bug, and it is not allowed
  to take the page with it: the hooks a page calls while rendering
  (`tournament_menu_entries/2`, `check_lineups/1`) are rescued, logged, and read as
  "nothing".
  """

  require Logger

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Team, Tournament}

  @compiled Application.compile_env(:pairings_engine, :plugins, [])

  # Tests register a fake plugin at run time (test/support/fake_plugin.ex);
  # nothing else may. Compiled out of every other build, so a production
  # application environment cannot add one.
  @runtime_plugins? Application.compile_env(:pairings_engine, :runtime_test_plugins, false)

  @doc """
  The plugins compiled into this build, as configured - what the router
  mounts. Evaluated at compile time; `all/0` is what code running later
  should ask.
  """
  @spec compiled() :: [module()]
  def compiled, do: @compiled

  @doc "The plugins active in this running application."
  @spec all() :: [module()]
  if @runtime_plugins? do
    def all, do: @compiled ++ Application.get_env(:pairings_engine, :test_plugins, [])
  else
    def all, do: @compiled
  end

  @doc "Whether any plugin is active."
  def any?, do: not Enum.empty?(all())

  @doc "The plugin whose `id/0` is `id`, or nil."
  def get(id) when is_binary(id), do: Enum.find(all(), &(&1.id() == id))

  ## ---------- routes ----------

  @doc """
  The routes `plugins` mount, as `{path, live_module, action}` with the
  path already under `/p/<id>`. Called by the router at compile time.
  """
  @spec routes([module()]) :: [{String.t(), module(), atom()}]
  def routes(plugins \\ compiled()) do
    own =
      for plugin <- plugins,
          Code.ensure_compiled!(plugin) && exports?(plugin, :routes, 0),
          {path, live, action} <- plugin.routes() do
        {"/p/" <> plugin.id() <> normalise_path(path), live, action}
      end

    # The "Installed plug-ins" page belongs to the seam rather than to a
    # plugin, and exists exactly when some plugin does.
    if plugins == [], do: [], else: [{"/plugins", PairingsEngineWeb.PluginsLive, :index} | own]
  end

  defp normalise_path(""), do: ""
  defp normalise_path("/" <> _ = path), do: String.trim_trailing(path, "/")
  defp normalise_path(path), do: normalise_path("/" <> path)

  ## ---------- menu ----------

  @doc """
  The installed plugins as the home screen's "Plug-ins" menu and the
  "Installed plug-ins" page list them, in build order: `[]` without one,
  and then the menu does not exist.
  """
  def installed do
    for plugin <- all() do
      %{
        id: plugin.id(),
        name: plugin.name(),
        description: plugin.description(),
        version: plugin.version(),
        path: plugin.start_path()
      }
    end
  end

  @doc """
  The top-bar links every active plugin offers `scope` inside `tournament`.
  """
  def tournament_menu_entries(_scope, nil), do: []

  # Plug-ins are for administrators only, their tournament entries included.
  def tournament_menu_entries(scope, tournament) do
    if admin?(scope), do: plugin_menu_entries(scope, tournament), else: []
  end

  @doc "Whether `scope`'s user may see and use plug-ins: administrators only."
  def admin?(%{user: user}), do: PairingsEngine.Authz.may_administer?(user)
  def admin?(_scope), do: false

  @doc "Every feature key a plugin adds (`features/0`)."
  def feature_keys, do: Enum.map(features(), & &1.key)

  defp plugin_menu_entries(scope, tournament) do
    Enum.flat_map(all(), fn plugin ->
      if exports?(plugin, :tournament_menu_entries, 2),
        do:
          safely(
            plugin,
            :tournament_menu_entries,
            fn -> plugin.tournament_menu_entries(scope, tournament) end,
            []
          ),
        else: []
    end)
  end

  ## ---------- page overlays ----------

  @doc """
  What the active plugins draw over every page (`page_overlay/1`), in build
  order, nils dropped. A plugin that raises draws nothing rather than
  taking the page down with it.
  """
  def page_overlays(assigns \\ %{}) do
    for plugin <- all(),
        exports?(plugin, :page_overlay, 1),
        rendered = safely(plugin, :page_overlay, fn -> plugin.page_overlay(assigns) end, nil),
        rendered != nil,
        do: rendered
  end

  ## ---------- features ----------

  @doc "The `PairingsEngine.Features` catalogue entries the plugins add."
  def features do
    Enum.flat_map(all(), fn plugin ->
      if exports?(plugin, :features, 0), do: plugin.features(), else: []
    end)
  end

  ## ---------- line-ups ----------

  @doc """
  Whether a plugin, not the roster's order, decides which board a player
  may sit at in `tournament`. The core then accepts a line-up out of
  roster order and leaves the judgement to `check_lineups/1`.
  """
  @spec plugin_board_order?(Tournament.t()) :: boolean()
  def plugin_board_order?(%Tournament{} = tournament) do
    Enum.any?(all(), fn plugin ->
      exports?(plugin, :board_order, 1) and
        safely(plugin, :board_order, fn -> plugin.board_order(tournament) end, :roster) ==
          :plugin
    end)
  end

  @doc "Whether any plugin checks line-ups at all."
  def checks_lineups?, do: Enum.any?(all(), &exports?(&1, :check_lineups, 1))

  @doc """
  The findings every plugin has about the line-ups of `match`, round
  `round_number`: `ids_a`/`ids_b` are player ids (nil for an empty seat),
  board 1 first, as on the match page's form - the line-ups being entered,
  saved or not.

  `nil` when no plugin checks line-ups for this tournament, so a page can
  tell "nobody checked" from "checked, nothing found" (`[]`).
  """
  @spec check_lineups(Tournament.t(), map(), pos_integer(), [integer() | nil], [integer() | nil]) ::
          [PairingsEngine.Plugin.finding()] | nil
  def check_lineups(%Tournament{} = t, match, round_number, ids_a, ids_b) do
    checkers = Enum.filter(all(), &exports?(&1, :check_lineups, 1))

    if checkers == [] do
      nil
    else
      match = with_teams(match)
      players = t.id |> Tournaments.list_players() |> Map.new(&{&1.id, &1})
      per_match = max(t.team_boards || 1, 1)

      context = %{
        tournament: t,
        match: match,
        round_number: round_number,
        team_a: match.team_a,
        team_b: match.team_b,
        lineup_a: seats(ids_a, players, per_match),
        lineup_b: seats(ids_b, players, per_match)
      }

      results =
        Enum.map(checkers, fn plugin ->
          safely(plugin, :check_lineups, fn -> plugin.check_lineups(context) end, nil)
        end)

      if Enum.all?(results, &is_nil/1),
        do: nil,
        else: results |> Enum.reject(&is_nil/1) |> List.flatten() |> sort_findings()
    end
  end

  defp seats(ids, players, per_match) do
    ids
    |> Enum.take(per_match)
    |> then(&(&1 ++ List.duplicate(nil, per_match - length(&1))))
    |> Enum.map(&(&1 && Map.get(players, &1)))
  end

  defp sort_findings(findings) do
    Enum.sort_by(findings, fn f ->
      {if(f.severity == :violation, do: 0, else: 1), f.board || 0, to_string(f.team)}
    end)
  end

  ## ---------- schedule ----------

  @doc """
  The team numbers and Berger table size a plugin fixes for `tournament`'s
  team round robin - `%{size: n, numbers: %{team_id => number}}` - or nil
  (the core's own numbering and table).
  """
  def team_schedule(%Tournament{} = tournament) do
    Enum.find_value(all(), fn plugin ->
      if exports?(plugin, :team_schedule, 1), do: plugin.team_schedule(tournament)
    end)
  end

  ## ---------- rosters ----------

  @doc """
  What each plugin can put on `team`'s roster: `[{plugin, label, candidates}]`
  with `candidates` player attributes (string keys, as
  `Tournaments.create_player/2` takes them) in roster order. Anyone already
  in the tournament under the same national or FIDE ID is left out, and so
  is a plugin left with nobody to offer.
  """
  def roster_candidates(scope, %Tournament{} = t, %Team{} = team) do
    offering =
      for plugin <- all(),
          exports?(plugin, :roster_candidates, 3),
          {:ok, label, candidates} <- [plugin.roster_candidates(scope, t, team)],
          do: {plugin, label, candidates}

    if offering == [] do
      []
    else
      existing = Tournaments.list_players(t.id)

      for {plugin, label, candidates} <- offering,
          fresh = fresh(candidates, existing),
          fresh != [],
          do: {plugin, label, fresh}
    end
  end

  defp fresh(candidates, existing) do
    national = existing |> Enum.map(& &1.national_id) |> Enum.reject(&(&1 in [nil, ""]))
    fide = existing |> Enum.map(& &1.fide_id) |> Enum.reject(&is_nil/1)

    Enum.reject(candidates, fn c ->
      to_string(c["national_id"] || "") in national or
        (not is_nil(c["fide_id"]) and parse_int(c["fide_id"]) in fide)
    end)
  end

  @doc """
  Adds `candidates` (as `roster_candidates/3` gives them) to the bottom of
  `team`'s roster, in order, skipping anyone already in the tournament.
  Returns `{:ok, added_count}`, or the first refusal.
  """
  def add_to_roster(%Tournament{} = t, %Team{} = team, candidates) when is_list(candidates) do
    fresh = fresh(candidates, Tournaments.list_players(t.id))

    Enum.reduce_while(fresh, {:ok, 0}, fn attrs, {:ok, n} ->
      with {:ok, %Player{} = p} <- Tournaments.create_player(t.id, attrs),
           {:ok, _} <- Tournaments.set_player_team(Repo.reload!(t), p, team) do
        {:cont, {:ok, n + 1}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp parse_int(n) when is_integer(n), do: n

  defp parse_int(text) do
    case Integer.parse(to_string(text)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  ## ---------- migrations ----------

  @doc "The plugins' own migration directories, run after the core's."
  def migrations_paths do
    for plugin <- all(), exports?(plugin, :migrations_path, 0) do
      plugin.migrations_path()
    end
  end

  ## ---------- helpers ----------

  # `function_exported?/3` is false for a module not loaded yet - and under
  # `mix phx.server` (how the hosted server runs) modules load on first use,
  # so a hook asked before anything else touched the plugin would read as
  # missing. Load first, then ask.
  defp exports?(module, fun, arity),
    do: Code.ensure_loaded?(module) and function_exported?(module, fun, arity)

  defp safely(plugin, hook, fun, fallback) do
    fun.()
  rescue
    error ->
      Logger.error(
        "Plugin #{inspect(plugin)} raised in #{hook}: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      fallback
  end

  # The match page's match is preloaded with its teams; one that is not
  # gets them here.
  defp with_teams(%{team_a: %Team{}, team_b: %Team{}} = match), do: match
  defp with_teams(match), do: Repo.preload(match, [:team_a, :team_b], force: true)
end
