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

  `available` says whether this installation can actually calculate it.
  Three team-only breaks cannot: team standings are not built, so
  `PairingsEngine.Standings` has no clause for them and its catch-all
  returns 0.0. Offering them was a silent, permanent tie at zero - an
  arbiter could add "Match points" to a Swiss, see a column of noughts, and
  have nothing tell them why.

  Unavailable codes are excluded from the picker (`selectable/0`) and
  dropped by `PairingsEngine.Standings.dropped_tiebreaks/2` with a reason,
  through the same path C.07 Art. 10 uses for rating-based breaks when an
  unrated player is present. They stay in `catalogue/0` because a stored
  tournament may already carry one - the FIDE team-event defaults below
  include all three, and SWAR files map codes by number - and a name still
  has to resolve.
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
      available: false,
      description: "Team events: 2 points per match won, 1 per drawn match."
    },
    %{
      code: "GP",
      name: "Game points",
      scope: :team,
      available: false,
      description: "Team events: sum of individual board points."
    },
    %{
      code: "BB",
      name: "Board points weighted (Berlin)",
      scope: :team,
      available: false,
      description: "Team events: board points weighted by board number."
    }
  ]

  # FIDE's own default sets, reproduced rather than edited. The two team
  # entries name MP/GP/BB, which nothing here can calculate yet - a team
  # tournament created from the preset therefore stores three codes that
  # `PairingsEngine.Standings` drops, and its Standings page says which and
  # why. That is the honest state: changing FIDE's defaults to hide our own
  # gap would misreport the regulation.
  @fide_defaults %{
    "swiss" => ~w(BHC1 BH SB DE WIN PS),
    "roundrobin" => ~w(DE WIN SB KS),
    "team-swiss" => ~w(MP GP DE BB SB),
    "team-roundrobin" => ~w(MP GP DE BB SB)
  }

  def catalogue, do: @catalogue

  @doc """
  The catalogue minus what this installation cannot calculate - what a
  tiebreak picker may offer.
  """
  def selectable, do: Enum.filter(@catalogue, & &1.available)

  @doc "Codes present in the catalogue that nothing here can calculate yet."
  def unavailable_codes, do: for(%{code: code, available: false} <- @catalogue, do: code)

  @doc "Whether `code` is one this installation can calculate."
  def available?(code), do: code not in unavailable_codes()

  def get(code), do: Enum.find(@catalogue, &(&1.code == code))

  def fide_defaults(type), do: Map.get(@fide_defaults, type, [])

  # Maps a FIDE tiebreak `code` (as used in `tournament.tiebreaks`) to the
  # column key the Players grid (`PairingsEngineWeb.PlayersLive`) and the
  # Standings page's column-visibility filter both use - only the
  # tiebreaks either page actually renders as its own toggleable column.
  # Anything else (WIN, KS, MP, GP, BB - team/round-robin-only breaks with
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
