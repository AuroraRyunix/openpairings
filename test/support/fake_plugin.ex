defmodule PairingsEngine.FakePlugin do
  @moduledoc """
  A plugin for the seam's own tests (`PairingsEngine.Plugin`). Registered at
  run time with `register/0` - `PairingsEngine.Plugins.all/0` reads
  `:test_plugins` in the test environment only - so it is active for the
  tests that ask for it and absent everywhere else, which is what lets the
  same suite prove both "no plugin, no trace" and "a plugin is called".

  It acts only on tournaments whose name starts with "Fake", so a test that
  registers it can still build ordinary tournaments beside them. What it
  answers is steered through the application environment
  (`:fake_plugin`): `:raise` makes every page-time hook raise, `:schedule`
  is the `team_schedule/1` answer, `:candidates` the roster offer.
  """
  @behaviour PairingsEngine.Plugin

  alias PairingsEngine.Tournaments.Tournament

  @doc "Makes the fake plugin active until the calling test ends."
  def register(opts \\ []) do
    Application.put_env(:pairings_engine, :test_plugins, [__MODULE__])
    Application.put_env(:pairings_engine, :fake_plugin, opts)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:pairings_engine, :test_plugins)
      Application.delete_env(:pairings_engine, :fake_plugin)
    end)
  end

  defp opt(key), do: :pairings_engine |> Application.get_env(:fake_plugin, []) |> Keyword.get(key)

  defp ours?(%Tournament{name: name}), do: String.starts_with?(name || "", "Fake")

  defp maybe_raise, do: if(opt(:raise), do: raise("fake plugin failure"))

  @impl true
  def id, do: "fake"
  @impl true
  def name, do: "Fake League"
  @impl true
  def description, do: "A plugin that exists only in the test suite."
  @impl true
  def version, do: "9.9.9"
  @impl true
  def start_path, do: "/p/fake"

  @impl true
  def routes, do: [{"/", __MODULE__, :index}, {"/series/:id", __MODULE__, :show}]

  @impl true
  def tournament_menu_entries(_scope, %Tournament{} = t) do
    maybe_raise()

    if ours?(t),
      do: [%{id: "fake", label: "Fake series", path: "/p/fake/series/#{t.id}"}],
      else: []
  end

  @impl true
  def features do
    [
      %{
        key: "fake_league",
        federation: "BEL",
        label: "Fake league",
        description: "The fake plugin's switch."
      }
    ]
  end

  @impl true
  def board_order(t), do: if(ours?(t), do: :plugin, else: :roster)

  @impl true
  def check_lineups(%{tournament: t} = context) do
    maybe_raise()

    if ours?(t) do
      seated = Enum.count(context.lineup_a, & &1)

      [
        %{
          severity: :violation,
          team: :a,
          board: 1,
          rule: "Art. 1.a",
          message: "Team A seats #{seated} players.",
          penalty: "Game lost by forfeit"
        },
        %{
          severity: :warning,
          team: nil,
          board: nil,
          rule: "Art. 2",
          message: "Looked.",
          penalty: nil
        }
      ]
    end
  end

  @impl true
  def team_schedule(t) do
    case ours?(t) && opt(:schedule) do
      plan when is_function(plan, 1) -> plan.(t)
      plan when is_map(plan) -> plan
      _ -> nil
    end
  end

  @impl true
  def roster_candidates(_scope, t, _team) do
    if ours?(t), do: {:ok, "the fake list", opt(:candidates) || []}, else: :none
  end
end
