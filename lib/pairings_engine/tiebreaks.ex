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

  @base_catalogue [
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
      scope: :both,
      available: true,
      description: "Buchholz minus the lowest-scoring opponent."
    },
    %{
      code: "BHC2",
      name: "Buchholz Cut-2",
      scope: :both,
      available: true,
      description: "Buchholz minus the two lowest-scoring opponents."
    },
    %{
      code: "MBH",
      name: "Median Buchholz",
      scope: :both,
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
    # ---- C.07 individual tie-breaks added for FIDE's checklist (VCL4THP Q104, Q199) ----
    # Their codes are C.07's own spelling (see `PairingsEngine.Standings.AinalramiBridge`),
    # the values are Ainalrami's.
    %{
      code: "BH/M2",
      name: "Median Buchholz, Median-2",
      scope: :individual,
      available: true,
      description:
        "Buchholz minus the two highest and the two lowest-scoring opponents (C.07 Art. 14.3)."
    },
    %{
      code: "FB",
      name: "Fore Buchholz",
      scope: :individual,
      available: true,
      description:
        "Buchholz as it stood before the last round: the last round's result is taken as a draw for every opponent (C.07 Art. 8.2)."
    },
    %{
      code: "FB/C1",
      name: "Fore Buchholz Cut-1",
      scope: :individual,
      available: true,
      description: "Fore Buchholz minus the lowest-scoring opponent."
    },
    %{
      code: "FB/C2",
      name: "Fore Buchholz Cut-2",
      scope: :individual,
      available: true,
      description: "Fore Buchholz minus the two lowest-scoring opponents."
    },
    %{
      code: "FB/M1",
      name: "Fore Median Buchholz",
      scope: :individual,
      available: true,
      description: "Fore Buchholz minus the highest and lowest-scoring opponents."
    },
    %{
      code: "FB/M2",
      name: "Fore Median Buchholz, Median-2",
      scope: :individual,
      available: true,
      description: "Fore Buchholz minus the two highest and the two lowest-scoring opponents."
    },
    %{
      code: "AOB",
      name: "Average of opponents' Buchholz",
      scope: :individual,
      available: true,
      description: "Average Buchholz of the opponents met over the board (C.07 Art. 8.2)."
    },
    %{
      code: "AOB/F",
      name: "Average of opponents' Fore Buchholz",
      scope: :individual,
      available: true,
      description: "Average Fore Buchholz of the opponents met over the board."
    },
    %{
      code: "SB/C1",
      name: "Sonneborn-Berger Cut-1",
      scope: :individual,
      available: true,
      description: "Sonneborn-Berger without the contribution of the lowest-scoring opponent."
    },
    %{
      code: "SB/C2",
      name: "Sonneborn-Berger Cut-2",
      scope: :individual,
      available: true,
      description:
        "Sonneborn-Berger without the contributions of the two lowest-scoring opponents."
    },
    %{
      code: "PS/C1",
      name: "Progressive score Cut-1",
      scope: :individual,
      available: true,
      description: "Progressive score without the first round's running score."
    },
    %{
      code: "PS/C2",
      name: "Progressive score Cut-2",
      scope: :individual,
      available: true,
      description: "Progressive score without the first two rounds' running scores."
    },
    %{
      code: "KS/L1",
      name: "Koya system, limit 50% + 1/2",
      scope: :individual,
      available: true,
      description: "Koya system with the qualifying limit raised by half a point."
    },
    %{
      code: "KS/L2",
      name: "Koya system, limit 50% + 1",
      scope: :individual,
      available: true,
      description: "Koya system with the qualifying limit raised by a point."
    },
    %{
      code: "KS/L-1",
      name: "Koya system, limit 50% - 1/2",
      scope: :individual,
      available: true,
      description: "Koya system with the qualifying limit lowered by half a point."
    },
    %{
      code: "KS/L-2",
      name: "Koya system, limit 50% - 1",
      scope: :individual,
      available: true,
      description: "Koya system with the qualifying limit lowered by a point."
    },
    %{
      code: "DE/P",
      name: "Direct encounter, forfeits counted",
      scope: :individual,
      available: true,
      description:
        "Direct encounter in which forfeit wins and losses count as games played (C.07 Art. 6.1.1)."
    },
    %{
      code: "BWG",
      name: "Games won with Black",
      scope: :individual,
      available: true,
      description: "Games won over the board with the black pieces (C.07 Art. 7.4)."
    },
    %{
      code: "REP",
      name: "Rounds effectively played",
      scope: :individual,
      available: true,
      description:
        "Rounds, minus half-point byes, zero-point byes and forfeit losses (C.07 Art. 7.6)."
    },
    %{
      code: "STD",
      name: "Standard points",
      scope: :individual,
      available: true,
      description:
        "One point per round scoring more than the opponent, half a point for the same (C.07 Art. 7.7)."
    },
    %{
      code: "TPN",
      name: "Tournament pairing number",
      scope: :individual,
      available: true,
      description: "The pairing number, the lower the better (C.07 Art. 7.8)."
    },
    %{
      code: "TPN/R",
      name: "Tournament pairing number, reversed",
      scope: :individual,
      available: true,
      description: "The pairing number, the higher the better."
    },
    %{
      code: "ARO/C2",
      name: "Average rating of opponents, Cut-2",
      scope: :individual,
      available: true,
      description: "ARO excluding the two lowest-rated opponents."
    },
    %{
      code: "ARO/M1",
      name: "Average rating of opponents, Median-1",
      scope: :individual,
      available: true,
      description: "ARO excluding the highest- and lowest-rated opponents."
    },
    %{
      code: "ARO/M2",
      name: "Average rating of opponents, Median-2",
      scope: :individual,
      available: true,
      description: "ARO excluding the two highest- and the two lowest-rated opponents."
    },
    %{
      code: "TPR",
      name: "Tournament performance rating",
      scope: :individual,
      available: true,
      description: "Performance rating from the opponents' ratings and the score."
    },
    %{
      code: "PTP",
      name: "Perfect tournament performance",
      scope: :individual,
      available: true,
      description: "The lowest rating at which the score is expected or better."
    },
    %{
      code: "APRO",
      name: "Average performance rating of opponents",
      scope: :individual,
      available: true,
      description: "Average TPR of the opponents met over the board."
    },
    %{
      code: "APPO",
      name: "Average perfect performance of opponents",
      scope: :individual,
      available: true,
      description: "Average PTP of the opponents met over the board."
    },
    %{
      code: "RTNG",
      name: "Tournament rating",
      scope: :individual,
      available: true,
      description: "The player's rating, the higher the better (C.07 Art. 10.6)."
    },
    %{
      code: "RTNG/R",
      name: "Tournament rating, reversed",
      scope: :individual,
      available: true,
      description: "The player's rating, the lower the better."
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
      code: "BH:GP",
      name: "Buchholz on game points",
      scope: :team,
      available: true,
      description:
        "Team events: the sum of the opponents' game points (C.07 Art. 8.1 with Art. 13, game points as the score)."
    },
    %{
      code: "EGMSB",
      name: "Extended Sonneborn-Berger, opponent's game points x match points scored",
      scope: :team,
      available: true,
      description:
        "Team events: each opponent's game points times the match points scored against them (C.07 Art. 13.2.3)."
    },
    %{
      code: "EGGSB",
      name: "Extended Sonneborn-Berger, opponent's game points x game points scored",
      scope: :team,
      available: true,
      description:
        "Team events: each opponent's game points times the game points scored against them (C.07 Art. 13.2.4)."
    },
    %{
      code: "EDE",
      name: "Extended Direct Encounter for teams",
      scope: :team,
      available: true,
      description:
        "Team events: direct encounter on match points, then on game points, among the tied teams (C.07 Art. 13.3)."
    },
    %{
      code: "TBR",
      name: "Top Board Results",
      scope: :team,
      available: true,
      description:
        "Team events: compares the tied teams' results board by board from board 1 down (C.07 Art. 12.2)."
    },
    %{
      code: "BBE",
      name: "Bottom Board Elimination",
      scope: :team,
      available: true,
      description:
        "Team events: drops the lowest board's results one at a time until the tie is broken (C.07 Art. 12.3)."
    },
    %{
      code: "SSSC",
      name: "Scores and Schedule Strength Combination",
      scope: :team,
      available: true,
      description:
        "Team events: the secondary score plus a measure of the opponents' strength (C.07 Art. 13.4)."
    },
    %{
      code: "BB",
      name: "Board points weighted (Berlin)",
      scope: :team,
      available: true,
      description: "Team events: board points weighted by board number, board 1 weighing most."
    }
  ]

  # Where a tie-break sits in the picker, and the two properties the standings
  # need to know about it. `rating?`: C.07 Article 10's rating-based family,
  # dropped when an unrated player is present unless a rating is set for them
  # (`Tournament.tiebreak_unrated_rating`). `buchholz?`: Article 8's family,
  # which "must not be used in round-robins".
  @groups %{
    "BH" => :buchholz,
    "BHC1" => :buchholz,
    "BHC2" => :buchholz,
    "MBH" => :buchholz,
    "BH/M2" => :buchholz,
    "FB" => :buchholz,
    "FB/C1" => :buchholz,
    "FB/C2" => :buchholz,
    "FB/M1" => :buchholz,
    "FB/M2" => :buchholz,
    "AOB" => :buchholz,
    "AOB/F" => :buchholz,
    "SB" => :sonneborn,
    "SB/C1" => :sonneborn,
    "SB/C2" => :sonneborn,
    "KS" => :sonneborn,
    "KS/L1" => :sonneborn,
    "KS/L2" => :sonneborn,
    "KS/L-1" => :sonneborn,
    "KS/L-2" => :sonneborn,
    "PS" => :progressive,
    "PS/C1" => :progressive,
    "PS/C2" => :progressive,
    "DE" => :results,
    "DE/P" => :results,
    "WIN" => :results,
    "WON" => :results,
    "BPG" => :results,
    "BWG" => :results,
    "REP" => :results,
    "STD" => :results,
    "TPN" => :results,
    "TPN/R" => :results,
    "ARO" => :rating,
    "AROC1" => :rating,
    "ARO/C2" => :rating,
    "ARO/M1" => :rating,
    "ARO/M2" => :rating,
    "TPR" => :rating,
    "PTP" => :rating,
    "APRO" => :rating,
    "APPO" => :rating,
    "RTNG" => :rating,
    "RTNG/R" => :rating
  }

  @catalogue Enum.map(@base_catalogue, fn tb ->
               group = Map.get(@groups, tb.code, :team)

               Map.merge(tb, %{
                 group: group,
                 rating?: group == :rating,
                 buchholz?:
                   tb.code in ~w(BH BHC1 BHC2 MBH) or
                     String.starts_with?(tb.code, ["BH/", "FB", "AOB"])
               })
             end)

  @group_order [:results, :buchholz, :sonneborn, :progressive, :rating, :team]

  @doc "The picker's groups, in the order they are shown."
  def group_order, do: @group_order

  @doc "Whether `code` is one of C.07 Article 10's rating-based tie-breaks."
  def rating_based?(code), do: match?(%{rating?: true}, get(code))

  @doc "Whether `code` is Buchholz-based (Article 8): not for round-robins."
  def buchholz_based?(code), do: match?(%{buchholz?: true}, get(code))

  @doc """
  `selectable/1`, split into the picker's groups: `[{group, [entry]}]`, in
  `group_order/0`, empty groups left out.
  """
  def selectable_grouped(type, except \\ []) do
    by_group =
      type |> selectable() |> Enum.reject(&(&1.code in except)) |> Enum.group_by(& &1.group)

    for g <- @group_order, entries = Map.get(by_group, g), entries != [], do: {g, entries}
  end

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
