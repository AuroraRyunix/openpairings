defmodule PairingsEngine.Norms.TitleNorms do
  @moduledoc """
  Automatic title-norm judgment per the FIDE International Title Regulations
  (B.01, effective 1 January 2024, verified against handbook.fide.com) - for
  each player, evaluates whether this tournament's games amount to a GM /
  IM / WGM / WIM norm (the four norm-based titles; FM/CM/WFM/WCM are direct
  rating titles with no norms, B.01 art. 1.3/1.4).

  ## What is checked (article references per check)

    * **Counted games** (1.4.1 / 1.4.2): only games played over the board -
      forfeits/adjudications are excluded (1.4.2.3), byes have no opponent.
      A norm needs at least 9 of them (1.4.1 (a)), except where the
      tournament's `norm_event_type` says it is one of the events 1.4.1 (b)
      lowers that for - see "Event types" below. 1.4.1 (c)'s 9-round
      allowance (8 games after a win by forfeit or a pairing-allocated bye
      counting as a 9-game norm, once per title application) is NOT
      applied: it is a property of the application, not of this event, so a
      judgment here stays conservative on game count.

      **An UNRATED game counts.** 1.4.2 excludes a game "decided by
      forfeit, adjudication or any means other than over the board play";
      it says nothing about rating. A game recorded `1-0U` was decided over
      the board and is unrated for RATING purposes only, which is a
      different question. So it counts toward the norm, at full value.

      Worth stating, because nothing here reads a result code:
      `counted_games/2` filters on the `played` flag
      `PairingsEngine.Standings` sets, and that flag is true for `W`/`D`/`L`
      because those are played games. The right answer therefore fell out of
      a module that has never heard of them - a fragile way to be correct,
      so `title_norms_test.exs` now asserts both halves: the unrated game
      counting, and a forfeit on the same board not.

      This is also what makes 1.4.5's "double round-robin tournaments need
      a minimum of 6 players" redundant rather than missing: a 5-player DRR
      is 8 games, which the 9-game rule already refuses. The 7- and 8-game
      concessions of 1.4.1 (b) apply to team championships and the World
      Cup, none of which is a double round-robin of individuals, so the rule
      still never bites.
    * **Score** (1.4.8.2): at least 35% (percentage rounded to the nearest
      whole number, 0.5 up - the 1.4.9 note's rounding rule).
    * **Titled opponents** (1.4.5.1): at least 50% of opponents hold any
      title EXCEPT CM/WCM.
    * **Target-title opponents** (1.4.5 b-e): at least 1/3 (rounded
      up per 1.4.4's minimum-rounding rule), with a minimum of 3, hold the
      target title *or higher* - GM for a GM norm; IM/GM for IM; WGM/IM/GM
      for WGM; WIM/WGM/IM/GM for WIM.

      **The double-round-robin halving is already satisfied here, and must
      not be "added".** 1.4.5's final clause says the number required by
      b-e is halved (rounded up) for a DRR, which reads like an exemption
      this module skips. It isn't. The two sides count in different units:
      `counted_games/2` emits one entry per GAME, so a DRR opponent appears
      twice and `high_titled` is already double the number of distinct
      titled players - while the Annex counts distinct people (its columns
      are "Different MO" / "Different TH") and halves the requirement to
      match. The halving exists to cancel the doubling. At 10 rounds (a
      6-player DRR, the smallest permitted): 1/3 of 10 with a minimum of 3
      is 4, halved to 2 *different* target-title opponents; this module
      asks for 4 game-instances, which in a complete DRR IS 2 different
      people. Halving `high_needed` on top of the per-game count would ask
      for one distinct titled opponent where FIDE asks for two.
      `title_norms_test.exs`'s DRR pair sits on that boundary so the
      mistake cannot land silently.

      In an INCOMPLETE DRR the two can diverge, and only in the safe
      direction: instances ≤ 2 × distinct, so passing here always implies
      passing the Annex, never the reverse.
    * **Federation mix** (1.4.3 / 1.4.4): opponents from at least two
      federations other than the player's own; at most 3/5 of opponents
      from the player's own federation and at most 2/3 from any single
      federation (maxima rounded DOWN per 1.4.4). The exemptions of 1.4.3
      (a)-(c) follow the tournament's `norm_event_type` - see "Event
      types" below. 1.4.3 (d) (a Swiss with at least 20 foreign rated
      players from 3+ federations, 10 of them titled, in every round) is not
      detected; an arbiter reporting such an event should treat a
      federation-mix failure here as overridable.
    * **Opponent ratings** (1.4.6 / 1.4.7): an unrated opponent counts as
      1400 (1.4.6.4); at most ONE opponent - the lowest - is raised to the
      norm's adjusted rating floor (2200 GM / 2050 IM / 2000 WGM / 1850
      WIM) when below it (1.4.6.2-1.4.6.3); the average is rounded to the
      nearest whole number, 0.5 up (1.4.7.2), and must reach 2380 GM /
      2230 IM / 2180 WGM / 2030 WIM (1.4.8.1).
    * **Performance** (1.4.8 / 1.4.9): `Rp = Ra + dp`, `dp` from the 1.4.9
      table keyed by the rounded score percentage, must reach 2600 GM /
      2450 IM / 2400 WGM / 2250 WIM.

  ## Event types (`Tournament.norm_event_type`)

  An "ordinary" tournament - the default, and every tournament before the
  field existed - is judged exactly as described above. The other kinds are
  applied only where they fit (`Tournament.effective_norm_event_type/1`):
  the team kinds on a team tournament, the individual kinds on an individual
  one. Each player's own board games are what is judged, as for an
  individual event.

    * **World or Continental Team / Club Championship** (1.4.1 (b)): 7
      games are enough when the event has 7, 8 or 9 rounds (the
      tournament's scheduled `rounds_count`). Outside 7-9 rounds the
      article grants nothing and 9 games are needed.
    * **World Cup / Women's World Cup** (1.4.1 (b)): 8 games are enough;
      the article adds that such a norm counts as 9 games, which matters to
      the title application, not to this judgment.
    * **Final stage of a national championship** (1.4.3 (a)) and **national
      team championship** (1.4.3 (b)): the federation-mix requirement is
      lifted, but only for players of the federation that registers the
      event - read as the tournament's own `federation`. Left blank, nobody
      is exempt. 1.4.3 (a)'s carve-out (no exemption in a year that
      federation holds its own Zonal or Sub-zonal) is the arbiter's to
      apply by choosing the type; 1.4.3 (b)'s ban on combining divisions is
      likewise not checked here.
    * **Zonal / Sub-zonal** (1.4.3 (c)): the federation-mix requirement is
      lifted for everyone.

  Reading of "the federation-mix requirement": 1.4.3 itself names only the
  two-foreign-federations rule, but its paragraph (d) falls back to 1.4.4
  when the exemption is not met, and paragraph (e) calls the rule being
  relaxed the normal foreigner requirement, pointing at both 1.4.3 and
  1.4.4 - so an exemption lifts the 1.4.4 maxima too. (Without that, a
  national championship whose field is all one federation could never
  yield a norm and the exemption would be void.) Every exempted check says
  so, and repeats 1.4.3 (e): at least one norm of a title application must
  meet the normal requirement - something only the application can show.

  Women's titles (WGM/WIM) are restricted to women (B.01 0.3.1), so they
  are only evaluated for players with `sex == "w"`.

  This is a *judgment aid* for the arbiter filling IT4 - the title claimed
  on the report stays a manual field (appeals, exemptions and the
  unmodelled event-type concessions are the arbiter's call); this module
  says what the numbers themselves support and exactly which requirement
  fails otherwise.

  Scoring note: the tournament may use non-standard point values (SWAR
  3-2-1 etc.). Norm arithmetic always converts each played game back to
  the standard 1 / ½ / 0 scale by comparing the awarded points against the
  tournament's configured win/draw values.
  """

  alias PairingsEngine.Standings
  alias PairingsEngine.Tournaments.Tournament

  @norm_titles ~w(GM IM WGM WIM)

  # B.01 art. 1.4.8.1 (min average opponent rating), 1.4.8 (min performance),
  # 1.4.6.2 (adjusted rating floor).
  @requirements %{
    "GM" => %{min_avg: 2380, min_perf: 2600, floor: 2200, counts_as_titled_or_higher: ~w(GM)},
    "IM" => %{min_avg: 2230, min_perf: 2450, floor: 2050, counts_as_titled_or_higher: ~w(IM GM)},
    "WGM" => %{
      min_avg: 2180,
      min_perf: 2400,
      floor: 2000,
      counts_as_titled_or_higher: ~w(WGM IM GM)
    },
    "WIM" => %{
      min_avg: 2030,
      min_perf: 2250,
      floor: 1850,
      counts_as_titled_or_higher: ~w(WIM WGM IM GM)
    }
  }

  # B.01 art. 1.4.6.4.
  @unrated_rating 1400

  # B.01 art. 1.4.9 - the p (score percentage) -> dp conversion table,
  # transcribed verbatim from the handbook (verified complete + perfectly
  # antisymmetric: dp(p) == -dp(100 - p), which the test suite asserts).
  @dp_by_percent %{
    100 => 800,
    99 => 677,
    98 => 589,
    97 => 538,
    96 => 501,
    95 => 470,
    94 => 444,
    93 => 422,
    92 => 401,
    91 => 383,
    90 => 366,
    89 => 351,
    88 => 336,
    87 => 322,
    86 => 309,
    85 => 296,
    84 => 284,
    83 => 273,
    82 => 262,
    81 => 251,
    80 => 240,
    79 => 230,
    78 => 220,
    77 => 211,
    76 => 202,
    75 => 193,
    74 => 184,
    73 => 175,
    72 => 166,
    71 => 158,
    70 => 149,
    69 => 141,
    68 => 133,
    67 => 125,
    66 => 117,
    65 => 110,
    64 => 102,
    63 => 95,
    62 => 87,
    61 => 80,
    60 => 72,
    59 => 65,
    58 => 57,
    57 => 50,
    56 => 43,
    55 => 36,
    54 => 29,
    53 => 21,
    52 => 14,
    51 => 7,
    50 => 0,
    49 => -7,
    48 => -14,
    47 => -21,
    46 => -29,
    45 => -36,
    44 => -43,
    43 => -50,
    42 => -57,
    41 => -65,
    40 => -72,
    39 => -80,
    38 => -87,
    37 => -95,
    36 => -102,
    35 => -110,
    34 => -117,
    33 => -125,
    32 => -133,
    31 => -141,
    30 => -149,
    29 => -158,
    28 => -166,
    27 => -175,
    26 => -184,
    25 => -193,
    24 => -202,
    23 => -211,
    22 => -220,
    21 => -230,
    20 => -240,
    19 => -251,
    18 => -262,
    17 => -273,
    16 => -284,
    15 => -296,
    14 => -309,
    13 => -322,
    12 => -336,
    11 => -351,
    10 => -366,
    9 => -383,
    8 => -401,
    7 => -422,
    6 => -444,
    5 => -470,
    4 => -501,
    3 => -538,
    2 => -589,
    1 => -677,
    0 => -800
  }

  @doc false
  def dp_for_percent(pct) when pct in 0..100, do: Map.fetch!(@dp_by_percent, pct)

  @doc """
  Evaluates every player of `tournament`, returning
  `%{player_id => %{verdicts: [verdict], best: verdict | nil, games: n}}`.

  Each verdict is `%{title:, achieved?:, checks: [check], performance:,
  avg_opponent_rating:, score:, games:}` - `checks` is the full
  requirement-by-requirement breakdown (`%{name:, ok?:, detail:}`), so the
  UI can say exactly which article fails. `best` is the highest achieved
  norm (GM > IM > WGM > WIM), or nil.
  """
  def evaluate(tournament) do
    entries = Standings.standings(tournament)
    by_id = Map.new(entries, &{&1.player.id, &1})

    event_type = Tournament.effective_norm_event_type(tournament)

    Map.new(entries, fn entry ->
      games = counted_games(entry, by_id)

      verdicts =
        Enum.map(
          titles_for(entry.player),
          &evaluate_norm(&1, entry.player, games, tournament, event_type)
        )

      best = Enum.find(verdicts, & &1.achieved?)

      {entry.player.id, %{verdicts: verdicts, best: best, games: length(games)}}
    end)
  end

  @doc "Titles evaluated for `player` - women's titles only for `sex == \"w\"` (B.01 0.3.1)."
  def titles_for(%{sex: "w"}), do: @norm_titles
  def titles_for(_player), do: ~w(GM IM)

  # A game that counts for norm purposes: played over the board (excludes
  # forfeits - B.01 1.4.2.3) against a real opponent (excludes byes), with
  # its result known (excludes a postponed game still to be played, which
  # counts in the standings as a draw nobody has played yet).
  # Returns `[%{opponent: %Player{}, points: awarded}]` - `points` is still
  # on the tournament's own (possibly club-configured) scale; `to_standard/2`
  # converts to 1 / ½ / 0 at evaluation time.
  defp counted_games(entry, by_id) do
    entry.games
    |> Enum.filter(&(PairingsEngine.Standings.finished_game?(&1) and &1.opponent_id != nil))
    |> Enum.flat_map(fn g ->
      case by_id[g.opponent_id] do
        nil -> []
        opp_entry -> [%{opponent: opp_entry.player, points: g.points}]
      end
    end)
  end

  defp evaluate_norm(title, player, games, tournament, event_type) do
    req = Map.fetch!(@requirements, title)
    n = length(games)
    {min_games, games_note} = minimum_games(event_type, tournament)
    fed_exemption = federation_exemption(event_type, player, tournament)

    score =
      games
      |> Enum.map(&to_standard(&1.points, tournament))
      |> Enum.sum()

    opponents = Enum.map(games, & &1.opponent)

    # --- ratings: unrated -> 1400, then raise only the single lowest
    # opponent to the norm's adjusted floor when below it (1.4.6.2-1.4.6.4).
    ratings = Enum.map(opponents, &max(fide_rating(&1), @unrated_rating))

    adjusted_ratings =
      case Enum.sort(ratings) do
        [] -> []
        [lowest | rest] -> [max(lowest, req.floor) | rest]
      end

    avg =
      case adjusted_ratings do
        [] -> nil
        list -> round_half_up(Enum.sum(list) / length(list))
      end

    score_pct = if n > 0, do: round_half_up(score / n * 100), else: 0
    perf = if avg, do: avg + dp_for_percent(clamp(score_pct, 0, 100)), else: nil

    # --- titled-opponent mix (1.4.5)
    titled = Enum.count(opponents, &(&1.title in ~w(GM IM WGM WIM FM WFM)))
    high_titled = Enum.count(opponents, &(&1.title in req.counts_as_titled_or_higher))
    high_needed = max(3, ceil(n / 3))

    # --- federation mix (1.4.3 / 1.4.4); maxima rounded DOWN per 1.4.4.
    own_fed = normalize_fed(player.federation)
    opp_feds = Enum.map(opponents, &normalize_fed(&1.federation))
    foreign_feds = opp_feds |> Enum.reject(&(&1 in [nil, own_fed])) |> Enum.uniq() |> length()
    own_fed_count = Enum.count(opp_feds, &(&1 != nil and &1 == own_fed))

    max_one_fed =
      opp_feds
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> Map.values()
      |> Enum.max(fn -> 0 end)

    checks =
      [
        check(
          :games,
          n >= min_games,
          "#{n} counted game#{plural(n)} (need #{min_games}#{games_note}; forfeits and byes never count)"
        ),
        check(
          :score,
          n > 0 and score_pct >= 35,
          "score #{fmt_half(score)}/#{n} = #{score_pct}% (need 35%)"
        ),
        check(
          :titled_opponents,
          n > 0 and titled * 2 >= n,
          "#{titled}/#{n} titled opponents, CM/WCM excluded (need 50%)"
        ),
        check(
          :high_titled_opponents,
          high_titled >= high_needed,
          "#{high_titled} opponent#{plural(high_titled)} holding #{Enum.join(req.counts_as_titled_or_higher, "/")} (need #{high_needed})"
        ),
        federation_check(
          fed_exemption,
          :foreign_federations,
          foreign_feds >= 2,
          "opponents from #{foreign_feds} federation#{plural(foreign_feds)} other than #{own_fed || "?"} (need 2; national championship/zonal exemptions follow the event type on the FIDE settings page)"
        ),
        federation_check(
          fed_exemption,
          :own_federation_share,
          n == 0 or own_fed_count <= div(3 * n, 5),
          "#{own_fed_count}/#{n} opponents from own federation (max #{div(3 * n, 5)} = 3/5 rounded down)"
        ),
        federation_check(
          fed_exemption,
          :single_federation_share,
          n == 0 or max_one_fed <= div(2 * n, 3),
          "largest single-federation group #{max_one_fed}/#{n} (max #{div(2 * n, 3)} = 2/3 rounded down)"
        ),
        check(
          :avg_opponent_rating,
          avg != nil and avg >= req.min_avg,
          "average opponent rating #{avg || "-"} (need #{req.min_avg}; unrated count as 1400, one floor-raise to #{req.floor})"
        ),
        check(
          :performance,
          perf != nil and perf >= req.min_perf,
          "performance #{perf || "-"} = #{avg || "-"} + dp(#{score_pct}%) (need #{req.min_perf})"
        )
      ]

    %{
      title: title,
      achieved?: Enum.all?(checks, & &1.ok?),
      checks: checks,
      performance: perf,
      avg_opponent_rating: avg,
      score: score,
      games: n
    }
  end

  defp check(name, ok?, detail), do: %{name: name, ok?: !!ok?, detail: detail}

  @doc """
  B.01 1.4.1 (a)/(b): the fewest counted games a norm can rest on for
  `event_type` (an effective `norm_event_type`), with a note naming the
  concession when one applies - `{9, ""}` when none does. The team / club
  concession needs the event to have 7, 8 or 9 rounds; the World Cup one
  does not.
  """
  def minimum_games(event_type, tournament)
      when event_type in ~w(team_championship club_championship) do
    case Map.get(tournament, :rounds_count) do
      rounds when rounds in 7..9 -> {7, " - 1.4.1 (b), #{rounds}-round team/club championship"}
      _ -> {9, ""}
    end
  end

  def minimum_games("world_cup", _tournament),
    do: {8, " - 1.4.1 (b), World Cup; counts as 9 games in the title application"}

  def minimum_games(_event_type, _tournament), do: {9, ""}

  @doc """
  B.01 1.4.3 (a)-(c): the paragraph that lifts the federation mix for
  `player` under `event_type`, or nil. (a) and (b) reach only players of
  the federation that registers the event, read as the tournament's own
  `federation`; (c) reaches everyone.
  """
  def federation_exemption("zonal", _player, _tournament), do: "1.4.3 (c)"

  def federation_exemption(event_type, player, tournament)
      when event_type in ~w(national_championship national_team_championship) do
    registering = fed_key(Map.get(tournament, :federation))

    if registering != nil and fed_key(player.federation) == registering do
      if event_type == "national_championship", do: "1.4.3 (a)", else: "1.4.3 (b)"
    end
  end

  def federation_exemption(_event_type, _player, _tournament), do: nil

  # A federation-mix check, or - under a 1.4.3 exemption - the same check
  # passed, saying which paragraph lifted it and what 1.4.3 (e) still asks.
  defp federation_check(nil, name, ok?, detail), do: check(name, ok?, detail)

  defp federation_check(paragraph, name, _ok?, detail) do
    check(
      name,
      true,
      "#{detail} - exempt under #{paragraph}; per 1.4.3 (e) at least one norm of the title application must meet the normal federation requirement"
    )
  end

  defp fed_key(fed) when is_binary(fed) do
    case fed |> String.trim() |> String.upcase() do
      "" -> nil
      key -> key
    end
  end

  defp fed_key(_), do: nil

  # Awarded configured points -> standard 1 / ½ / 0 (see moduledoc).
  #
  # The points arriving here are `Standings.pairing_records/4`'s, which ADD
  # SWAR's 3-2-1 presence point on top of the result value rather than
  # folding it into `points_win`/`points_draw` - those are imported as the
  # result-only figures. Banding the raw total against them therefore shifted
  # every played game one band UP on a 3-2-1 event: with 2/1/0 scoring and a
  # presence point, a win stored 3.0 and matched neither band (read as a
  # LOSS), a draw stored 2.0 and matched `points_win` (read as a WIN), a loss
  # stored 1.0 and matched `points_draw` (read as a DRAW).
  #
  # Not an occasional misread - a uniform inversion, so `score` and every
  # check derived from it were wrong for every player in the event. Strip
  # the presence component before banding.
  defp to_standard(points, t) do
    presence = presence_component(t)
    points = points - presence

    cond do
      points == t.points_win -> 1.0
      points == t.points_draw -> 0.5
      true -> 0.0
    end
  end

  # Mirrors `Standings.presence_points/2`'s own guard: nil for every
  # tournament that is not a 3-2-1 import, which keeps this a no-op there.
  defp presence_component(t) do
    case Map.get(t, :presence_value) do
      value when is_number(value) -> value
      _ -> 0.0
    end
  end

  # Norm arithmetic uses the FIDE rating only - B.01 1.4.6.1's "Rating List
  # in effect" is FIDE's, never a national list.
  defp fide_rating(%{fide_rating: r}) when is_integer(r) and r > 0, do: r
  defp fide_rating(_), do: 0

  defp normalize_fed(nil), do: nil
  defp normalize_fed(""), do: nil
  defp normalize_fed(fed), do: fed

  # B.01 1.4.7.2 / the 1.4.9 note: round to nearest whole, 0.5 upward.
  defp round_half_up(value), do: trunc(:math.floor(value + 0.5))

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)

  defp plural(1), do: ""
  defp plural(_), do: "s"

  defp fmt_half(score) do
    if score == trunc(score), do: "#{trunc(score)}", else: "#{score}"
  end
end
