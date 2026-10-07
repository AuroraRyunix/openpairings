defmodule PairingsEngine.Plugin do
  @moduledoc """
  The contract a compile-time plugin implements. A plugin adds something
  one installation needs and the published application does not - a
  national competition's own rules, say - without the core knowing it
  exists.

  ## How a plugin gets into a build

  Only at compile time, and only in the hosted edition. `mix.exs` reads
  `PAIRINGS_EDITION`: unset or `desktop` (CI, the desktop binaries, local
  development) lists no plugin, so no plugin source is compiled, nothing
  references one, and the application is exactly what it is without this
  module. `PAIRINGS_EDITION=hosted` adds each plugin as a path dependency
  and compiles its `lib/` together with the core. A plugin is a checkout
  with an `openpairings_plugin.exs` manifest (`[name: ..., module: ...]`)
  in `PAIRINGS_PLUGINS_DIR` - by default the directory next to this
  checkout - and `PAIRINGS_PLUGINS` names which ones (all of them when
  unset); the core names none. Compiling with the core is what lets a
  plugin's pages `use PairingsEngineWeb, :live_view` and render inside
  `Layouts.app` like every other page. `config/config.exs` hands the list
  to `PairingsEngine.Plugins`, which every hook below goes through.

  ## The hooks

  Deliberately few - each exists because a plugin needed it, and a hook
  nobody calls is an interface nobody tests.

    * `id/0`, `name/0`, `description/0`, `version/0`, `start_path/0` -
      the plugin's slug (its pages live under `/p/<id>`), and what the
      home screen's "Plug-ins" menu and the "Installed plug-ins" page
      (`PairingsEngineWeb.PluginsLive`) show and open. That menu is the
      only place a plugin appears in the home screen's top bar, and it
      exists only in a build with a plugin.
    * `routes/0` - LiveViews mounted under `/p/<id>` in the router's
      `:plugins` live_session: signed in, same hooks as a tournament page.
    * `tournament_menu_entries/2` - links in a tournament's top bar.
    * `features/0` - entries appended to `PairingsEngine.Features`, so a
      plugin's pages are switched on per account like a federation pack.
    * `board_order/1` - `:plugin` when the plugin's regulations, not the
      roster's order, decide which board a player may sit at in this
      tournament; the core then stops refusing a line-up out of roster
      order and the plugin's own check reports instead.
    * `check_lineups/1` - findings about the two line-ups of a team match
      (nil when the plugin has no say over this tournament), per board, shown while the line-ups are entered and before results
      make them final. Findings only: a check never changes a line-up, a
      pairing or a result.
    * `team_schedule/1` - the team numbers and Berger table size a team
      round robin is paired with, when a league's regulations fix them -
      or, with `:rounds`, every round listed as `{home, away}` number
      pairs (a held number in no pair has the bye).
      A table that is not the one C.05 Annex 1 gives the field takes the
      tournament out of FIDE mode at the first round paired from it
      (`PairingsEngine.TeamRoundRobin`).
    * `roster_candidates/3` - players a plugin can put on a team's roster
      from its own data, offered on the Teams page.
    * `migrations_path/0` - the plugin's own migrations, run with the
      core's.

  The five identity callbacks are required; every hook is optional.

  ## FIDE mode

  A plugin hook never changes a pairing or a result on its own. Anything a
  plugin wants to change about who plays whom, or what a game is worth,
  goes through the same settings `PairingsEngine.Compliance` reads, and
  departs from FIDE mode exactly as an arbiter's change would.
  """

  alias PairingsEngine.Accounts.Scope
  alias PairingsEngine.Tournaments.{Match, Player, Team, Tournament}

  @typedoc "One link in the top bar."
  @type menu_entry :: %{id: String.t(), label: String.t(), path: String.t()}

  @typedoc """
  The line-ups being checked: `lineup_a`/`lineup_b` hold one entry per
  board of the match, board 1 first, a `%Player{}` or nil for an empty
  seat. `team_a` is the first-named team (White on the odd boards).
  """
  @type lineup_context :: %{
          tournament: Tournament.t(),
          match: Match.t(),
          round_number: pos_integer(),
          team_a: Team.t(),
          team_b: Team.t(),
          lineup_a: [Player.t() | nil],
          lineup_b: [Player.t() | nil]
        }

  @typedoc """
  One problem with a line-up.

    * `:severity` - `:violation` (the regulations forbid it) or `:warning`
      (worth a look, not forbidden).
    * `:team` - `:a`, `:b`, or nil for the match as a whole.
    * `:board` - the board it is about, or nil.
    * `:rule` - the article it applies, as the regulations number it.
    * `:message` - the sentence, already in the reader's language.
    * `:penalty` - what the regulations give for it, or nil.
  """
  @type finding :: %{
          severity: :violation | :warning,
          team: :a | :b | nil,
          board: pos_integer() | nil,
          rule: String.t(),
          message: String.t(),
          penalty: String.t() | nil
        }

  @callback id() :: String.t()
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback version() :: String.t()
  @callback start_path() :: String.t()
  @callback routes() :: [{String.t(), module(), atom()}]
  @callback tournament_menu_entries(Scope.t() | nil, Tournament.t()) :: [menu_entry()]
  @callback features() :: [map()]
  @callback board_order(Tournament.t()) :: :roster | :plugin
  @callback check_lineups(lineup_context()) :: [finding()] | nil
  @callback team_schedule(Tournament.t()) ::
              %{
                required(:size) => pos_integer(),
                required(:numbers) => %{integer() => pos_integer()},
                optional(:rounds) => [[{pos_integer(), pos_integer()}]]
              }
              | nil
  @callback roster_candidates(Scope.t(), Tournament.t(), Team.t()) ::
              {:ok, String.t(), [map()]} | :none
  @callback migrations_path() :: String.t()

  @optional_callbacks routes: 0,
                      tournament_menu_entries: 2,
                      features: 0,
                      board_order: 1,
                      check_lineups: 1,
                      team_schedule: 1,
                      roster_candidates: 3,
                      migrations_path: 0
end
