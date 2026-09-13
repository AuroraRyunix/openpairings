defmodule PairingsEngine.Tiebreaks do
  @moduledoc """
  Tiebreak catalogue, following the FIDE Tie-Break Regulations (C.07).
  Codes follow the abbreviations used in the regulations.

  ## Two fields, both read

  `scope` says who a tiebreak is for - `:individual`, `:team`, or `:both`.
  It replaces a `teams:` boolean that was never read anywhere and had gone
  internally inconsistent while nobody was looking: Direct encounter and
  Number of wins were marked `teams: true` although they are ordinary
  individual tiebreaks (both sit in the FIDE default set for an individual
  Swiss), while Buchholz and Sonneborn-Berger were marked `teams: false`
  although C.07 Art. 13.2 defines them for team events too.

  `available` says whether this installation can calculate it at all. Every
  code in the catalogue now can - the team-only breaks since team standings
  were built (`PairingsEngine.TeamStandings`) - but a code is only
  calculable where its scope fits: individual standings cannot compute a
  team-only break, and team standings compute only
  `TeamStandings.supported_codes/0`. `selectable/1` offers a tournament
  exactly what fits it, and each standings module drops the rest with a
  reason (`Standings.dropped_tiebreaks_with_reasons/2`,
  `TeamStandings.dropped_tiebreaks_with_reasons/1`) rather than showing a
  column of noughts.

  The flag stays so a code that is catalogued for its name - a stored
  tournament, a SWAR file mapping codes by number - but not implemented can
  be marked so again without a second mechanism.
  """

  @catalogue [
    %{
      code: "BH",
      name: "Buchholz",
      scope: :both,
      available: true,
      description: "Sum of the scores of all opponents."
    },
    %{
      code: "BHC1",
      name: "Buchholz Cut-1",
      scope: :individual,
      available: true,
      description: "Buchholz minus the lowest-scoring opponent."
    },
    %{
      code: "BHC2",
      name: "Buchholz Cut-2",
      scope: :individual,
      available: true,
      description: "Buchholz minus the two lowest-scoring opponents."
    },
    %{
      code: "MBH",
      name: "Median Buchholz",
      scope: :individual,
      available: true,
      description: "Buchholz minus the highest and lowest-scoring opponents."
    },
    %{
      code: "SB",
      name: "Sonneborn-Berger",
      scope: :both,
      available: true,
      description:
        "Sum of the scores of beaten opponents plus half the scores of drawn opponents."
    },
    %{
      code: "DE",
      name: "Direct encounter",
      scope: :both,
      available: true,
      description: "Result(s) of the game(s) between the tied participants."
    },
    %{
      code: "WIN",
      name: "Number of wins",
      scope: :both,
      available: true,
      description: "Total number of games won (including forfeits)."
    },
    %{
      code: "WON",
      name: "Number of games won over the board",
      scope: :individual,
      available: true,
      description: "Games won, excluding forfeits and byes."
    },
    %{
      code: "BPG",
      name: "Games played with Black",
      scope: :individual,
      available: true,
      description: "Number of games played with the black pieces."
    },
    %{
      code: "PS",
      name: "Progressive score",
      scope: :individual,
      available: true,
      description: "Sum of the running score after each round."
    },
    %{
      code: "KS",
      name: "Koya system",
      scope: :individual,
      available: true,
      description: "Score against opponents who scored 50% or more."
    },
    %{
      code: "ARO",
      name: "Average rating of opponents",
      scope: :individual,
      available: true,
      description: "Average rating of all opponents."
    },
    %{
      code: "AROC1",
      name: "Average rating of opponents, Cut-1",
      scope: :individual,
      available: true,
      description: "ARO excluding the lowest-rated opponent."
    },
    %{
      code: "MP",
      name: "Match points",
      scope: :team,
      available: true,
      description:
        "Team events: match points (C.07 Art. 11.1.1), 2 per match won and 1 per match drawn by default."
    },
    %{
      code: "GP",
      name: "Game points",
      scope: :team,
      available: true,
      description: "Team events: sum of the individual board points (C.07 Art. 11.1.2)."
    },
    %{
      code: "EMGSB",
      name: "Sonneborn-Berger, match points x game points",
      scope: :team,
      available: true,
      description:
        "Team events: each opponent's match points times the game points scored against them (C.07 Art. 13.2.2)."
    },
    %{
      code: "BB",
      name: "Board points weighted (Berlin)",
      scope: :team,
      available: true,
      description: "Team events: board points weighted by board number, board 1 weighing most."
    }
  ]

  # FIDE's own default sets, reproduced rather than edited. The two team
  # entries name MP/GP/DE/BB/SB, all of which `PairingsEngine.TeamStandings`
  # calculates.
  @fide_defaults %{
    "swiss" => ~w(BHC1 BH SB DE WIN PS),
    "roundrobin" => ~w(DE WIN SB KS),
    "team-swiss" => ~w(MP GP DE BB SB),
    "team-roundrobin" => ~w(MP GP DE BB SB)
  }

  def catalogue, do: @catalogue

  @doc """
  The catalogue minus what this installation cannot calculate and minus the
  team-only breaks - what an individual tournament's tiebreak picker may
  offer. Unchanged in what it returns since before team standings existed.
  """
  def selectable, do: Enum.filter(@catalogue, &(&1.available and &1.scope != :team))

  @doc """
  What a picker may offer a tournament of `type`: `selectable/0` for an
  individual event, and for a team event the breaks team standings calculate
  (`PairingsEngine.TeamStandings.supported_codes/0`), in catalogue order.
  """
  def selectable(type) when type in ["team-swiss", "team-roundrobin"] do
    supported = PairingsEngine.TeamStandings.supported_codes()
    Enum.filter(@catalogue, &(&1.available and &1.code in supported))
  end

  def selectable(_type), do: selectable()

  @doc "Codes present in the catalogue that nothing here can calculate yet."
  def unavailable_codes, do: for(%{code: code, available: false} <- @catalogue, do: code)

  @doc "Whether `code` is one this installation can calculate somewhere."
  def available?(code), do: code not in unavailable_codes()

  @doc """
  Whether INDIVIDUAL standings can calculate `code`: available, and not a
  team-only break. `Standings` drops anything else as not calculable.
  """
  def individual_calculable?(code) do
    case get(code) do
      %{scope: :team} -> false
      _ -> available?(code)
    end
  end

  def get(code), do: Enum.find(@catalogue, &(&1.code == code))

  def fide_defaults(type), do: Map.get(@fide_defaults, type, [])

  # Maps a FIDE tiebreak `code` (as used in `tournament.tiebreaks`) to the
  # column key the Players grid (`PairingsEngineWeb.PlayersLive`) and the
  # Standings page's column-visibility filter both use - only the
  # tiebreaks either page actually renders as its own toggleable column.
  # Anything else (WIN, KS, MP, GP, EMGSB, BB - team/round-robin-only breaks with
  # no dedicated grid column) returns `nil`.
  @grid_keys %{
    "BH" => "buch",
    "BHC1" => "bc1",
    "SB" => "sb",
    "PS" => "prog",
    "DE" => "diren"
  }

  def grid_key(code), do: Map.get(@grid_keys, code)
end
