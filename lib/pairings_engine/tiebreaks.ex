defmodule PairingsEngine.Tiebreaks do
  @moduledoc """
  Tiebreak catalogue, following the FIDE Tie-Break Regulations (C.07).
  Codes follow the abbreviations used in the regulations. The calculation
  engine implements each of these; this module drives configuration.
  """

  @catalogue [
    %{
      code: "BH",
      name: "Buchholz",
      teams: false,
      description: "Sum of the scores of all opponents."
    },
    %{
      code: "BHC1",
      name: "Buchholz Cut-1",
      teams: false,
      description: "Buchholz minus the lowest-scoring opponent."
    },
    %{
      code: "BHC2",
      name: "Buchholz Cut-2",
      teams: false,
      description: "Buchholz minus the two lowest-scoring opponents."
    },
    %{
      code: "MBH",
      name: "Median Buchholz",
      teams: false,
      description: "Buchholz minus the highest and lowest-scoring opponents."
    },
    %{
      code: "SB",
      name: "Sonneborn-Berger",
      teams: false,
      description:
        "Sum of the scores of beaten opponents plus half the scores of drawn opponents."
    },
    %{
      code: "DE",
      name: "Direct encounter",
      teams: true,
      description: "Result(s) of the game(s) between the tied participants."
    },
    %{
      code: "WIN",
      name: "Number of wins",
      teams: true,
      description: "Total number of games won (including forfeits)."
    },
    %{
      code: "WON",
      name: "Number of games won over the board",
      teams: false,
      description: "Games won, excluding forfeits and byes."
    },
    %{
      code: "BPG",
      name: "Games played with Black",
      teams: false,
      description: "Number of games played with the black pieces."
    },
    %{
      code: "PS",
      name: "Progressive score",
      teams: false,
      description: "Sum of the running score after each round."
    },
    %{
      code: "KS",
      name: "Koya system",
      teams: false,
      description: "Score against opponents who scored 50% or more."
    },
    %{
      code: "ARO",
      name: "Average rating of opponents",
      teams: false,
      description: "Average rating of all opponents."
    },
    %{
      code: "AROC1",
      name: "Average rating of opponents, Cut-1",
      teams: false,
      description: "ARO excluding the lowest-rated opponent."
    },
    %{
      code: "MP",
      name: "Match points",
      teams: true,
      description: "Team events: 2 points per match won, 1 per drawn match."
    },
    %{
      code: "GP",
      name: "Game points",
      teams: true,
      description: "Team events: sum of individual board points."
    },
    %{
      code: "BB",
      name: "Board points weighted (Berlin)",
      teams: true,
      description: "Team events: board points weighted by board number."
    }
  ]

  @fide_defaults %{
    "swiss" => ~w(BHC1 BH SB DE WIN PS),
    "roundrobin" => ~w(DE WIN SB KS),
    "team-swiss" => ~w(MP GP DE BB SB),
    "team-roundrobin" => ~w(MP GP DE BB SB)
  }

  def catalogue, do: @catalogue

  def get(code), do: Enum.find(@catalogue, &(&1.code == code))

  def fide_defaults(type), do: Map.get(@fide_defaults, type, [])

  # Maps a FIDE tiebreak `code` (as used in `tournament.tiebreaks`) to the
  # column key the Players grid (`PairingsEngineWeb.PlayersLive`) and the
  # Standings page's column-visibility filter both use — only the
  # tiebreaks either page actually renders as its own toggleable column.
  # Anything else (WIN, KS, MP, GP, BB — team/round-robin-only breaks with
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
