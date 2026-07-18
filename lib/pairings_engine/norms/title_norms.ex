defmodule PairingsEngine.Norms.TitleNorms do
  @moduledoc """
  Automatic title-norm judgment per the FIDE International Title Regulations
  (B.01, effective 1 January 2024, verified against handbook.fide.com) — for
  each player, evaluates whether this tournament's games amount to a GM /
  IM / WGM / WIM norm (the four norm-based titles; FM/CM/WFM/WCM are direct
  rating titles with no norms, B.01 art. 1.3/1.4).

  ## What is checked (article references per check)

    * **Counted games** (1.4.1 / 1.4.2): only games played over the board —
      forfeits/adjudications are excluded (1.4.2.3), byes have no opponent.
      A norm needs at least 9 of them. The 7/8-game concessions
      (1.4.1.1-1.4.1.3: World Team/Club championships, World Cup, an
      unplayed last-round win-by-forfeit) are event types this software
      doesn't model, so they are NOT applied — a judgment here is therefore
      conservative, never optimistic, on game count.
    * **Score** (1.4.8.2): at least 35% (percentage rounded to the nearest
      whole number, 0.5 up — the 1.4.9 note's rounding rule).
    * **Titled opponents** (1.4.5.1): at least 50% of opponents hold any
      title EXCEPT CM/WCM.
    * **Target-title opponents** (1.4.5.2-1.4.5.5): at least 1/3 (rounded
      up per 1.4.4's minimum-rounding rule), with a minimum of 3, hold the
      target title *or higher* — GM for a GM norm; IM/GM for IM; WGM/IM/GM
      for WGM; WIM/WGM/IM/GM for WIM. (The double-round-robin halving of
      1.4.5.6 is not applied — see the module limitation note below.)
    * **Federation mix** (1.4.3 / 1.4.4): opponents from at least two
      federations other than the player's own; at most 3/5 of opponents
      from the player's own federation and at most 2/3 from any single
      federation (maxima rounded DOWN per 1.4.4). The 1.4.3a-e exemptions
      (national championships, zonals, big Swisses with 20+ rated players
      per round from 3+ federations...) are not auto-detected; an arbiter
      reporting such an event should treat a federation-mix failure here as
      overridable.
    * **Opponent ratings** (1.4.6 / 1.4.7): an unrated opponent counts as
      1400 (1.4.6.4); at most ONE opponent — the lowest — is raised to the
      norm's adjusted rating floor (2200 GM / 2050 IM / 2000 WGM / 1850
      WIM) when below it (1.4.6.2-1.4.6.3); the average is rounded to the
      nearest whole number, 0.5 up (1.4.7.2), and must reach 2380 GM /
      2230 IM / 2180 WGM / 2030 WIM (1.4.8.1).
    * **Performance** (1.4.8 / 1.4.9): `Rp = Ra + dp`, `dp` from the 1.4.9
      table keyed by the rounded score percentage, must reach 2600 GM /
      2450 IM / 2400 WGM / 2250 WIM.

  Women's titles (WGM/WIM) are restricted to women (B.01 0.3.1), so they
  are only evaluated for players with `sex == "w"`.

  This is a *judgment aid* for the arbiter filling IT4 — the title claimed
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

  @norm_titles ~w(GM IM WGM WIM)

  # B.01 art. 1.4.8.1 (min average opponent rating), 1.4.8 (min performance),
  # 1.4.6.2 (adjusted rating floor).
  @requirements %{
    "GM" => %{min_avg: 2380, min_perf: 2600, floor: 2200, counts_as_titled_or_higher: ~w(GM)},
    "IM" => %{min_avg: 2230, min_perf: 2450, floor: 2050, counts_as_titled_or_higher: ~w(IM GM)},
    "WGM" => %{min_avg: 2180, min_perf: 2400, floor: 2000, counts_as_titled_or_higher: ~w(WGM IM GM)},
    "WIM" => %{min_avg: 2030, min_perf: 2250, floor: 1850, counts_as_titled_or_higher: ~w(WIM WGM IM GM)}
  }

  # B.01 art. 1.4.6.4.
  @unrated_rating 1400

  # B.01 art. 1.4.9 — the p (score percentage) -> dp conversion table,
  # transcribed verbatim from the handbook (verified complete + perfectly
  # antisymmetric: dp(p) == -dp(100 - p), which the test suite asserts).
  @dp_by_percent %{
    100 => 800, 99 => 677, 98 => 589, 97 => 538, 96 => 501, 95 => 470,
    94 => 444, 93 => 422, 92 => 401, 91 => 383, 90 => 366, 89 => 351,
    88 => 336, 87 => 322, 86 => 309, 85 => 296, 84 => 284, 83 => 273,
    82 => 262, 81 => 251, 80 => 240, 79 => 230, 78 => 220, 77 => 211,
    76 => 202, 75 => 193, 74 => 184, 73 => 175, 72 => 166, 71 => 158,
    70 => 149, 69 => 141, 68 => 133, 67 => 125, 66 => 117, 65 => 110,
    64 => 102, 63 => 95, 62 => 87, 61 => 80, 60 => 72, 59 => 65,
    58 => 57, 57 => 50, 56 => 43, 55 => 36, 54 => 29, 53 => 21,
    52 => 14, 51 => 7, 50 => 0, 49 => -7, 48 => -14, 47 => -21,
    46 => -29, 45 => -36, 44 => -43, 43 => -50, 42 => -57, 41 => -65,
    40 => -72, 39 => -80, 38 => -87, 37 => -95, 36 => -102, 35 => -110,
    34 => -117, 33 => -125, 32 => -133, 31 => -141, 30 => -149,
    29 => -158, 28 => -166, 27 => -175, 26 => -184, 25 => -193,
    24 => -202, 23 => -211, 22 => -220, 21 => -230, 20 => -240,
    19 => -251, 18 => -262, 17 => -273, 16 => -284, 15 => -296,
    14 => -309, 13 => -322, 12 => -336, 11 => -351, 10 => -366,
    9 => -383, 8 => -401, 7 => -422, 6 => -444, 5 => -470, 4 => -501,
    3 => -538, 2 => -589, 1 => -677, 0 => -800
  }

  @doc false
  def dp_for_percent(pct) when pct in 0..100, do: Map.fetch!(@dp_by_percent, pct)

  @doc """
  Evaluates every player of `tournament`, returning
  `%{player_id => %{verdicts: [verdict], best: verdict | nil, games: n}}`.

  Each verdict is `%{title:, achieved?:, checks: [check], performance:,
  avg_opponent_rating:, score:, games:}` — `checks` is the full
  requirement-by-requirement breakdown (`%{name:, ok?:, detail:}`), so the
  UI can say exactly which article fails. `best` is the highest achieved
  norm (GM > IM > WGM > WIM), or nil.
  """
  def evaluate(tournament) do
    entries = Standings.standings(tournament)
    by_id = Map.new(entries, &{&1.player.id, &1})

    Map.new(entries, fn entry ->
      games = counted_games(entry, by_id)
      verdicts = Enum.map(titles_for(entry.player), &evaluate_norm(&1, entry.player, games, tournament))

      best = Enum.find(verdicts, & &1.achieved?)

      {entry.player.id, %{verdicts: verdicts, best: best, games: length(games)}}
    end)
  end

  @doc "Titles evaluated for `player` — women's titles only for `sex == \"w\"` (B.01 0.3.1)."
  def titles_for(%{sex: "w"}), do: @norm_titles
  def titles_for(_player), do: ~w(GM IM)

  # A game that counts for norm purposes: played over the board (excludes
  # forfeits — B.01 1.4.2.3) against a real opponent (excludes byes).
  # Returns `[%{opponent: %Player{}, points: awarded}]` — `points` is still
  # on the tournament's own (possibly club-configured) scale; `to_standard/2`
  # converts to 1 / ½ / 0 at evaluation time.
  defp counted_games(entry, by_id) do
    entry.games
    |> Enum.filter(&(&1.played and &1.opponent_id != nil))
    |> Enum.flat_map(fn g ->
      case by_id[g.opponent_id] do
        nil -> []
        opp_entry -> [%{opponent: opp_entry.player, points: g.points}]
      end
    end)
  end

  defp evaluate_norm(title, player, games, tournament) do
    req = Map.fetch!(@requirements, title)
    n = length(games)

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
    max_one_fed = opp_feds |> Enum.reject(&is_nil/1) |> Enum.frequencies() |> Map.values() |> Enum.max(fn -> 0 end)

    checks =
      [
        check(:games, n >= 9, "#{n} counted game#{plural(n)} (need 9; forfeits and byes never count)"),
        check(:score, n > 0 and score_pct >= 35, "score #{fmt_half(score)}/#{n} = #{score_pct}% (need 35%)"),
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
        check(
          :foreign_federations,
          foreign_feds >= 2,
          "opponents from #{foreign_feds} federation#{plural(foreign_feds)} other than #{own_fed || "?"} (need 2; nat. championship/zonal exemptions not auto-detected)"
        ),
        check(
          :own_federation_share,
          n == 0 or own_fed_count <= div(3 * n, 5),
          "#{own_fed_count}/#{n} opponents from own federation (max #{div(3 * n, 5)} = 3/5 rounded down)"
        ),
        check(
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

  # Awarded configured points -> standard 1 / ½ / 0 (see moduledoc).
  defp to_standard(points, t) do
    cond do
      points == t.points_win -> 1.0
      points == t.points_draw -> 0.5
      true -> 0.0
    end
  end

  # Norm arithmetic uses the FIDE rating only — B.01 1.4.6.1's "Rating List
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
