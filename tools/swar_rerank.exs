# SWAR re-rank: real finished SWAR tournaments, ranked again by OpenPairings.
#
#   mix run --no-start tools/swar_rerank.exs [--out DIR] [--allow-321] PATH...
#
# PATH is a .swar file or a directory searched recursively for them. Each
# file goes through OpenPairings' own import (`SwarImport.import_file/3`) into
# a THROWAWAY SQLite database created for the run and deleted after it - the
# dev database is never opened - and its final standings come from
# `PairingsEngine.Standings`, whose tie-breaks are Ainalrami's. Those ranks and
# values are compared with what SWAR itself stored in the file: every
# `[JOUEURS]` record carries SWAR's `Class` (place), `Points` and the five
# `TieBreak` values as computed by SWAR's `CalculLeClassement` when the file
# was last saved.
#
# Three things are compared per event:
#
#   * ranks - SWAR's `Class` against OpenPairings' rank (per category when
#     SWAR ranks categories separately);
#   * tie-break values - each code of the tournament's SWAR list, SWAR's
#     stored number against OpenPairings' (the scale SWAR stores them in is
#     undone: Buchholz, SB, PS, DE and Koya are quarter points);
#   * the cause of each rank difference - for every pair of players the two
#     programs order differently, the first criterion of SWAR's own list on
#     which they stop agreeing, and why the values there differ.
#
# To tell "SWAR computes it differently" from "the file is stale" or "we
# read the file wrong", the script carries a port of SWAR's own ranking code
# (`Classement.cpp`, SWAR v6.65 FRBE, the routines named on each function
# below). The port run over the file must reproduce SWAR's stored values;
# where it does, a difference with OpenPairings is SWAR's algorithm, and the
# tags on it say which of SWAR's documented departures from C.07 apply to
# that player (docs/swar-import.md, "Tiebreaks: three places...").
#
# Output: a summary on stdout and, with --out, `report.md` and
# `report.json` in DIR. Reports name real players and tournaments: write
# them somewhere private, never into the repository. Nothing here is
# committed data - SWAR files are not in git.
#
# 3-2-1 files are skipped unless --allow-321 (OpenPairings refuses to
# import them); American tournaments are skipped (SWAR ranks them on
# American points, which OpenPairings has no equivalent of).

defmodule SwarRerank.Model do
  @moduledoc false
  # A port of the parts of SWAR's `Classement.cpp` and `Utils.cpp` that
  # produce the stored places and tie-break values - faithful, including
  # what reads as SWAR bugs, because its job is to reproduce SWAR's numbers,
  # not to be right. Works on `SwarImport.parse/2`'s player maps. All point
  # values are SWAR's internal quarter points (win = 4).

  import Bitwise

  @win 0x4000
  @draw 0x2000
  @lost 0x1000
  @zero_zero 0x0400
  @draw_zero 0x0200
  @zero_draw 0x0100
  @win_bye 0x0040
  @draw_bye 0x0020
  @lost_bye 0x0010
  @win_ff 0x0004
  @draw_ff 0x0002
  @lost_ff 0x0001
  @zero_zeroff 0x0008

  @normaux 0xF000
  @speciaux 0x0F00
  @byes 0x00F0
  @forfaits 0x000F
  @joues @normaux ||| @speciaux
  @non_joues @byes ||| @forfaits
  @r_win @win ||| @win_bye ||| @win_ff
  @r_lost @lost ||| @zero_draw ||| @lost_bye ||| @lost_ff ||| @zero_zeroff

  @table_absent 0x4000
  @table_forfait 0x2000
  @table_non_jouee 0x7000

  def swiss?(type), do: type in [0, 1, 2, 3]
  def robin?(type), do: type in [4, 5, 6]
  def swiss321?(type), do: type == 3
  def double?(type), do: type in [1, 5, 6, 8]

  @doc "Context for one file: players by Ni, the round horizon, tournament options."
  def context(data) do
    t = data.tournament
    players = data.players
    by_ni = Map.new(players, &{&1.ni, &1})

    ctx = %{
      t: t,
      by_ni: by_ni,
      last: last_round_with_result(players),
      rounds_paired: players |> Enum.map(&length(&1.rounds)) |> Enum.max(fn -> 0 end)
    }

    # Points first (every tie-break reads them), then the adjusted score.
    points = Map.new(players, &{&1.ni, all_points(&1, ctx)})
    ctx = Map.put(ctx, :points, points)
    adjusted = Map.new(players, &{&1.ni, adjusted_points(&1, ctx)})
    Map.put(ctx, :adjusted, adjusted)
  end

  # pRound + i, with a round past the player's own list read as missing.
  def rnd(p, i), do: Enum.at(p.rounds, i)

  # Utils.cpp GetLastRoundWithResult / TestIfResultsThisRound: the last
  # round in which at least one player has a result that is not a bye,
  # an absence or a withdrawal.
  def last_round_with_result(players) do
    max = players |> Enum.map(&length(&1.rounds)) |> Enum.max(fn -> 0 end)

    Enum.find(max..1//-1, 0, fn n ->
      i = n - 1

      Enum.any?(players, fn p ->
        case rnd(p, i) do
          nil ->
            false

          r ->
            r.table not in [@table_absent, @table_forfait] and (r.result &&& @byes) == 0 and
              r.result != 0
        end
      end)
    end)
  end

  # Utils.cpp ConvertPoint.
  def convert(result, ctx) do
    cond do
      (result &&& @byes) != 0 ->
        cond do
          swiss321?(ctx.t.type) -> ctx.t.sw321_bye * 4
          bye_value(ctx) == 0 -> 4
          bye_value(ctx) == 1 -> 2
          true -> 0
        end

      (result &&& @r_win) != 0 ->
        4

      (result &&& (@zero_zero ||| @draw ||| @draw_zero ||| @draw_bye ||| @draw_ff)) != 0 ->
        2

      true ->
        0
    end
  end

  # TournoiReadStream forces PTS_1 for every round robin at load.
  defp bye_value(ctx), do: if(robin?(ctx.t.type), do: 0, else: ctx.t.bye_value)

  # Utils.cpp ConvertPoint321.
  defp convert321(result, t) do
    cond do
      result in [@win_ff, @win] -> t.sw321_win
      result in [@draw_ff, @draw_zero, @draw] -> t.sw321_nul
      result in [@lost_ff, @zero_draw, @lost] -> t.sw321_los
      result == @lost_bye -> t.sw321_bye
      true -> 0
    end
  end

  # Utils.cpp GetNbAbsence (rounds 0..rnd inclusive).
  defp absences_through(p, rnd) do
    Enum.count(0..rnd//1, fn i ->
      case rnd(p, i) do
        nil -> false
        r -> r.table == @table_absent
      end
    end)
  end

  # Utils.cpp GetSpecialAbsValue: DRAW or LOST. (`AbsValue == PTS_0` compares
  # a 0/1 checkbox with 2 and is never true; the AbsJusque test does the work.)
  def special_abs(p, rnd, t) do
    cond do
      rnd > t.abs_jusque - 1 -> @lost
      absences_through(p, rnd) > t.abs_nbfois -> @lost
      true -> @draw
    end
  end

  # Utils.cpp GetPoints / Classement.cpp GetPointsUntilRound.
  defp all_points(p, ctx) do
    t = ctx.t

    Enum.reduce(0..(ctx.last - 1)//1, 0, fn i, acc ->
      case rnd(p, i) do
        nil ->
          acc

        r ->
          cond do
            swiss321?(t.type) -> acc + convert321(r.result, t)
            robin?(t.type) -> acc + convert(r.result, ctx)
            (r.result &&& @byes) != 0 -> acc + special_bye(ctx)
            r.table == @table_absent -> acc + convert(special_abs(p, i, t), ctx)
            true -> acc + convert(r.result, ctx)
          end
      end
    end)
  end

  # ConvertPoint(GetSpecialByeValue()): ByeValue as WIN/DRAW/LOST.
  defp special_bye(ctx) do
    case bye_value(ctx) do
      0 -> 4
      1 -> 2
      _ -> 0
    end
  end

  # Classement.cpp getBuchNonJouer + GetAdjustedPts (v6.49): half a point
  # for every round after which the player only lost by forfeit or was absent.
  defp adjusted_points(p, ctx) do
    last = ctx.last

    extra =
      Enum.count(0..(last - 1)//1, fn i ->
        i + 1 != last and
          Enum.all?((i + 1)..(last - 1)//1, fn k ->
            case rnd(p, k) do
              nil -> true
              r -> r.result == @lost_ff or r.table == @table_absent
            end
          end)
      end)

    ctx.points[p.ni] + 2 * extra
  end

  defp points(ctx, ni), do: Map.get(ctx.points, ni, 0)

  # Utils.cpp FindJoueurNumber: an unknown number gives a player with no
  # points, Class -1.
  defp find(ctx, ni), do: Map.get(ctx.by_ni, ni)

  @doc "Classement.cpp ComputeTieBreak, one code."
  def tiebreak(p, code, ctx) do
    if ctx.last < 2 do
      0
    else
      case code do
        12 -> aro(p, false, ctx)
        13 -> aro(p, true, ctx)
        15 -> black_won(p, ctx)
        14 -> black_played(p, ctx)
        11 -> perf(p, ctx)
        10 -> wins(p, ctx)
        9 -> koya(p, ctx)
        8 -> between(p, ctx)
        7 -> cumulate(p, ctx)
        c when c in 1..5 -> bucholtz(p, c, ctx)
        6 -> sonneborn(p, ctx)
        _ -> 0
      end
    end
  end

  defp rounds(ctx), do: 0..(ctx.last - 1)//1

  defp absent_or_forfait?(nil), do: true
  defp absent_or_forfait?(r), do: r.table in [@table_absent, @table_forfait]

  # Classement.cpp TieBucholtz (v6.49).
  def bucholtz(j1, dep, ctx) do
    last = ctx.last

    delete =
      cond do
        dep in [3, 5] -> min(div(last - 1, 4), 2)
        dep in [2, 4] -> min(div(last - 1, 4), 1)
        true -> 0
      end

    median? = dep in [2, 3]
    own = points(ctx, j1.ni)

    {correction, nb_absent} =
      Enum.reduce(rounds(ctx), {0, 0}, fn i, {corr, nb_abs} ->
        r = rnd(j1, i)

        cond do
          r == nil ->
            {corr, nb_abs}

          dep > 1 and r.table == @table_absent and nb_abs == 0 ->
            {corr, nb_abs + 1}

          true ->
            nb_abs = if dep > 1 and r.table == @table_absent, do: nb_abs + 1, else: nb_abs

            if (r.result &&& @non_joues) != 0 or (r.table &&& @table_non_jouee) != 0,
              do: {corr + own, nb_abs},
              else: {corr, nb_abs}
        end
      end)

    contributions =
      for j <- rounds(ctx),
          r = rnd(j1, j),
          r != nil,
          (r.table &&& @table_non_jouee) == 0,
          j2 = find(ctx, r.advers),
          j2 != nil,
          # SWAR compares the opponent's forfeit opponent with this
          # player's RANK, not their Ni (`r->Advers == j1.Rank`).
          not Enum.any?(rounds(ctx), fn k ->
            case rnd(j2, k) do
              nil -> false
              r2 -> (r2.result &&& @forfaits) != 0 and r2.advers == j1.rank
            end
          end),
          do: Map.get(ctx.adjusted, j2.ni, 0)

    total = Enum.sum(contributions) + correction

    if dep > 1 and nb_absent == 0 and delete > 0 do
      sorted = Enum.sort(contributions)
      init_low = List.duplicate(4 * last, delete)
      lows = Enum.take(Enum.sort(sorted ++ init_low), delete)
      highs = Enum.take(Enum.sort(sorted ++ List.duplicate(0, delete), :desc), delete)

      Enum.zip(lows, highs)
      |> Enum.reduce(total, fn {lo, hi}, acc ->
        acc = acc - lo
        acc = if median?, do: acc - hi, else: acc
        max(acc, 0)
      end)
    else
      total
    end
  end

  # Classement.cpp getSonnebornNonJouer: trailing absences, 0 for exactly one.
  def sb_correction(j2, ctx) do
    nb =
      Enum.reduce(rounds(ctx), 0, fn k, nb ->
        case rnd(j2, k) do
          nil -> nb + 1
          %{table: @table_absent} -> nb + 1
          _ -> 0
        end
      end)

    if nb == 1, do: 0, else: nb * 2
  end

  # Classement.cpp TieSonneborn (v6.49, v6.57).
  def sonneborn(j1, ctx) do
    own = points(ctx, j1.ni)

    Enum.reduce(rounds(ctx), 0, fn i, acc ->
      r = rnd(j1, i)

      cond do
        r == nil ->
          acc

        r.table == @table_forfait or (r.result &&& @r_lost) != 0 ->
          acc

        (r.result &&& @win_bye) != 0 or (r.result &&& @win_ff) != 0 ->
          acc + own

        (r.result &&& @draw_bye) != 0 ->
          acc + div(own, 2)

        r.table == @table_absent ->
          case special_abs(j1, i, ctx.t) do
            @draw -> acc + div(own, 2)
            @win -> acc + div(own, 2)
            _ -> acc
          end

        true ->
          j2 = find(ctx, r.advers)
          pts = if j2, do: points(ctx, j2.ni), else: 0
          correction = if j2, do: sb_correction(j2, ctx), else: 0

          cond do
            correction != 0 ->
              acc + pts + correction

            (r.result &&& (@draw ||| @draw_bye ||| @draw_ff ||| @draw_zero)) != 0 ->
              acc + div(pts, 2)

            (r.result &&& @r_win) != 0 ->
              acc + pts

            true ->
              acc
          end
      end
    end)
  end

  # Classement.cpp TieCumulate.
  def cumulate(p, ctx) do
    if robin?(ctx.t.type) do
      0
    else
      Enum.reduce(rounds(ctx), 0, fn k, acc ->
        r = rnd(p, k)
        weight = ctx.last - k

        cond do
          r == nil -> acc
          r.table == @table_absent -> acc + convert(special_abs(p, k, ctx.t), ctx) * weight
          r.table == @table_forfait -> acc
          true -> acc + convert(r.result, ctx) * weight
        end
      end)
    end
  end

  # Classement.cpp TieVictoires.
  def wins(p, ctx),
    do: Enum.count(rounds(ctx), fn k -> (r = rnd(p, k)) && r.result in [@win, @win_ff] end)

  # Classement.cpp TieKoya: opponents on at least half of LastRound x a
  # win (1/0.5/0), the result against them as it stands, forfeits included.
  def koya(p, ctx) do
    required = ctx.last * 2

    Enum.reduce(rounds(ctx), 0, fn k, acc ->
      with r when r != nil <- rnd(p, k),
           j2 when j2 != nil <- find(ctx, r.advers),
           true <- points(ctx, j2.ni) >= required do
        acc + convert(r.result, ctx)
      else
        _ -> acc
      end
    end)
  end

  def black_played(p, ctx),
    do:
      Enum.count(rounds(ctx), fn k ->
        r = rnd(p, k)
        not absent_or_forfait?(r) and r.color == -1
      end)

  def black_won(p, ctx),
    do:
      Enum.count(rounds(ctx), fn k ->
        r = rnd(p, k)
        not absent_or_forfait?(r) and r.color == -1 and r.result == @win
      end)

  # Utils.cpp GetElo(int, int), by `EloUsed`.
  def elo(nil, _t), do: 0

  def elo(p, t) do
    case t.elo_used do
      0 -> if p.elo != 0, do: p.elo, else: p.elo_fide
      1 -> if p.elo_fide != 0, do: p.elo_fide, else: p.elo
      _ -> max(p.elo, p.elo_fide)
    end
  end

  # Classement.cpp TieAro: played games against rated opponents; the cut
  # only when nothing was unplayed and every opponent was rated.
  def aro(p, cut1?, ctx) do
    {sum, n, min, flag} =
      Enum.reduce(rounds(ctx), {0, 0, 9999, false}, fn k, {sum, n, mini, flag} ->
        r = rnd(p, k)

        cond do
          absent_or_forfait?(r) ->
            {sum, n, mini, true}

          r.advers <= 0 ->
            {sum, n, mini, true}

          (r.result &&& @joues) == 0 ->
            {sum, n, mini, true}

          true ->
            e = elo(find(ctx, r.advers), ctx.t)

            if e == 0,
              do: {sum, n, mini, true},
              else: {sum + e, n + 1, if(e < mini, do: e, else: mini), flag}
        end
      end)

    {sum, n} = if cut1? and not flag, do: {sum - min, n - 1}, else: {sum, n}
    if n <= 0, do: 0, else: round(sum / n)
  end

  # Classement.cpp GetPerformance (T1 table, 400-point rule, rounding).
  @t1 [
    800,
    677,
    589,
    538,
    501,
    470,
    444,
    422,
    401,
    383,
    366,
    351,
    336,
    322,
    309,
    296,
    284,
    273,
    262,
    251,
    240,
    230,
    220,
    211,
    202,
    193,
    184,
    175,
    166,
    158,
    149,
    141,
    133,
    125,
    117,
    110,
    102,
    95,
    87,
    80,
    72,
    65,
    57,
    50,
    43,
    36,
    29,
    21,
    14,
    7,
    0
  ]

  def perf(p, ctx) do
    own = elo(p, ctx.t)

    games =
      for k <- rounds(ctx),
          r = rnd(p, k),
          not absent_or_forfait?(r),
          r.advers != 0,
          (r.result &&& @joues) != 0,
          do: r

    case games do
      [] ->
        0

      _ ->
        tot =
          Enum.reduce(games, 0, fn r, acc ->
            e2 = elo(find(ctx, r.advers), ctx.t)

            e2 =
              cond do
                own == 0 -> e2
                own - e2 > 400 -> own - 400
                e2 - own > 400 -> own + 400
                true -> e2
              end

            acc + e2
          end)

        w = Enum.reduce(games, 0, &(convert(&1.result, ctx) + &2))
        played = length(games)
        avg = round(tot / played)
        we = (25 * w + 5) |> div(played) |> min(100) |> max(0)
        gain = if we > 50, do: Enum.at(@t1, 100 - we), else: -Enum.at(@t1, we)
        avg + gain
    end
  end

  # Classement.cpp TieBetween (v4.13): only when every player on the same
  # points has met every other; -1 otherwise.
  def between(p, ctx) do
    own = points(ctx, p.ni)

    group =
      ctx.by_ni
      |> Map.values()
      |> Enum.filter(&(points(ctx, &1.ni) == own))
      |> Enum.filter(&(ctx.t.cat_separes == 0 or &1.cat_index == p.cat_index))
      |> Enum.map(& &1.ni)

    if own == 0 or length(group) < 2 do
      -1
    else
      ids = MapSet.new(group)

      met = fn a, b ->
        Enum.any?(ctx.by_ni[a].rounds, fn r -> r.advers == b and not absent_or_forfait?(r) end)
      end

      all_met? = Enum.all?(for a <- group, b <- group, a < b, do: met.(a, b))

      if all_met? do
        Enum.reduce(p.rounds, 0, fn r, acc ->
          if not absent_or_forfait?(r) and r.advers in ids and r.advers != p.ni,
            do: acc + convert(r.result, ctx),
            else: acc
        end)
      else
        -1
      end
    end
  end

  @doc """
  Classement.cpp CalculLeClassement + CmpCla: category (when separate),
  points + extra + special, the five tie-breaks, then Rank ascending.
  Returns `%{ni => class}` from the given tie-break values.
  """
  def classement(players, totals, ties, t) do
    players
    |> Enum.sort_by(fn p ->
      cat = if t.cat_separes != 0, do: max(p.cat_index, 1), else: 0
      {cat, -totals[p.ni], Enum.map(ties[p.ni], &(-&1)), p.rank}
    end)
    |> Enum.chunk_by(fn p -> if t.cat_separes != 0, do: max(p.cat_index, 1), else: 0 end)
    |> Enum.flat_map(fn chunk ->
      chunk |> Enum.with_index(1) |> Enum.map(fn {p, i} -> {p.ni, i} end)
    end)
    |> Map.new()
  end
end

defmodule SwarRerank do
  @moduledoc false

  import Bitwise

  alias PairingsEngine.{Repo, Standings}
  alias PairingsEngine.Federations.BEL.SwarImport
  alias PairingsEngine.Standings.AinalramiBridge
  alias SwarRerank.Model

  # SWAR's DEPARTAGES enum; `SwarImport`'s own mapping to OpenPairings codes.
  @swar_names %{
    0 => "-",
    1 => "Buchholz",
    2 => "Buchholz median-1",
    3 => "Buchholz median-2",
    4 => "Buchholz cut-1",
    5 => "Buchholz cut-2",
    6 => "Sonneborn-Berger",
    7 => "Cumulative",
    8 => "Direct encounter",
    9 => "Koya",
    10 => "Wins",
    11 => "Performance",
    12 => "ARO",
    13 => "ARO cut-1",
    14 => "Black games",
    15 => "Black wins"
  }
  @op_codes %{
    1 => "BH",
    2 => "MBH",
    4 => "BHC1",
    5 => "BHC2",
    6 => "SB",
    7 => "PS",
    8 => "DE",
    9 => "KS",
    10 => "WIN",
    12 => "ARO",
    13 => "AROC1",
    14 => "BPG"
  }
  # Stored on SWAR's quarter-point scale (FormatTie's 1- and 2-decimal formats).
  @quarter_codes [1, 2, 3, 4, 5, 6, 7, 8, 9]

  @types %{
    0 => "Swiss",
    1 => "Swiss (double rounds)",
    2 => "Swiss (accelerated)",
    3 => "Swiss 3-2-1",
    4 => "Round robin",
    5 => "Round robin (double)",
    6 => "Round robin (return)",
    7 => "American",
    8 => "American (double)"
  }

  # ---------------------------------------------------------------- setup

  def setup_db do
    db = Path.join(System.tmp_dir!(), "swar_rerank_#{System.unique_integer([:positive])}.db")

    conf =
      Application.get_env(:pairings_engine, Repo, [])
      |> Keyword.put(:database, db)
      |> Keyword.put(:pool_size, 1)
      |> Keyword.put(:log, false)

    Application.put_env(:pairings_engine, Repo, conf)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Repo.start_link()
    {:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: PairingsEngine.PubSub)
    Logger.configure(level: :warning)
    Ecto.Migrator.run(Repo, :up, all: true, log: false)
    db
  end

  def files(paths) do
    paths
    |> Enum.flat_map(fn path ->
      path = String.replace(path, "\\", "/")

      cond do
        File.dir?(path) -> Path.wildcard(Path.join(path, "**/*.{swar,SWAR,Swar}"))
        File.regular?(path) -> [path]
        true -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # ------------------------------------------------------------- one file

  def analyse(path, opts) do
    binary = File.read!(path)
    sha = :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower) |> binary_part(0, 12)
    base = %{file: path, sha: sha}

    case SwarImport.parse(binary, allow_swiss321: true) do
      {:error, reason} ->
        Map.merge(base, %{status: :parse_failed, reason: inspect(reason)})

      {:ok, data} ->
        t = data.tournament

        cond do
          t.type in [7, 8] ->
            Map.merge(base, %{
              status: :skipped,
              reason: "American (ranked on American points)",
              data: summary(data)
            })

          t.type == 3 and !opts[:allow_321] ->
            Map.merge(base, %{
              status: :skipped,
              reason: "3-2-1 (OpenPairings refuses the import)",
              data: summary(data)
            })

          data.players == [] ->
            Map.merge(base, %{status: :skipped, reason: "no players", data: summary(data)})

          true ->
            compare(path, data, base, opts)
        end
    end
  end

  defp summary(data) do
    t = data.tournament

    %{
      name: t.name,
      version: data.version,
      guid: data.guid,
      type: @types[t.type] || "type #{t.type}",
      rounds: t.nb_rounds,
      players: length(data.players),
      tiebreaks: Enum.map(data.tiebreaks, &@swar_names[&1])
    }
  end

  defp compare(path, data, base, _opts) do
    t = data.tournament
    ctx = Model.context(data)
    ties_codes = data.tiebreaks
    players = data.players

    # --- SWAR's own numbers, and the port's -------------------------------
    stored_points = Map.new(players, &{&1.ni, &1.points})
    model_points = ctx.points
    points_reproduced? = stored_points == model_points

    model_ties =
      Map.new(players, fn p -> {p.ni, Enum.map(ties_codes, &Model.tiebreak(p, &1, ctx))} end)

    stored_ties = Map.new(players, &{&1.ni, &1.tiebreak})

    ties_mismatch =
      for p <- players,
          {code, i} <- Enum.with_index(ties_codes),
          code != 0,
          Enum.at(stored_ties[p.ni], i) != Enum.at(model_ties[p.ni], i),
          do: {p.ni, i}

    totals = Map.new(players, &{&1.ni, &1.points + &1.extra_pts + &1.special_pts})
    stored_class = Map.new(players, &{&1.ni, &1.class})
    self_order = Model.classement(players, totals, stored_ties, t)
    swar_consistent? = self_order == stored_class

    finished? =
      ctx.last == t.nb_rounds and
        Enum.all?(players, fn p ->
          Enum.all?(Enum.take(p.rounds, ctx.last), fn r ->
            r.result != 0 or r.table in [0x4000, 0x2000] or r.advers == 0
          end)
        end)

    # --- OpenPairings --------------------------------------------------------
    case SwarImport.import_file(path, nil, allow_swiss321: true) do
      {:error, reason} ->
        Map.merge(base, %{
          status: :import_failed,
          reason: SwarImport.error_message(reason),
          data: summary(data)
        })

      {:ok, tournament, warnings} ->
        tournament = Repo.reload!(tournament)

        # Ranks as imported, before anything below changes the tournament.
        as_imported = Standings.standings(tournament)

        rank_diffs_as_imported =
          as_imported
          |> Enum.map(fn e -> {e.player.pairing_number, e.rank} end)
          |> Enum.count(fn {ni, rank} -> t.cat_separes == 0 and self_order[ni] != rank end)

        # SWAR ranks a Swiss on points + ExtraPts (`CalculLeClassement`) and
        # zeroes ExtraPts at load for a round robin or 3-2-1. The import
        # leaves `count_extra_points` off - a product decision
        # (docs/extra-points.md) - so the comparison below mirrors SWAR
        # instead and reports the two counts separately.
        extra? =
          Model.swiss?(t.type) and not Model.swiss321?(t.type) and
            Enum.any?(players, &(&1.extra_pts != 0))

        tournament =
          if extra?,
            do: tournament |> Ecto.Changeset.change(count_extra_points: true) |> Repo.update!(),
            else: tournament

        entries = if extra?, do: Standings.standings(tournament), else: as_imported
        op_players = Enum.map(entries, & &1.player)
        effective = Standings.effective_tiebreaks(tournament, op_players)
        dropped = Standings.dropped_tiebreaks_with_reasons(tournament, op_players)
        by_ni = Map.new(entries, &{&1.player.pairing_number, &1})

        completed =
          case entries do
            [e | _] -> e.completed_rounds
            [] -> 0
          end

        event = AinalramiBridge.event(entries, tournament, completed)

        # C.07's adjusted score (16.3) per SWAR number, beside SWAR's own
        # (`ctx.adjusted`), to tell where an opponent's score is the cause.
        c07_adjusted =
          Map.new(entries, fn e ->
            participant = event.participants[e.player.id]

            {e.player.pairing_number,
             Ainalrami.Tiebreaks.Unplayed.adjusted_score(participant.rounds, event)}
          end)

        ctx =
          ctx
          |> Map.put(:op_completed, completed)
          |> Map.put(:c07_adjusted, c07_adjusted)
          |> Map.put(:version, data.version)

        # DE's position within a tied group, and the C.07 place (shared
        # when the list runs out), as `Standings` ranks.
        {places, de_pos} = c07(event, entries, tournament, effective)

        # Alternative values, to name a cause instead of guessing one: the
        # Buchholz family at every cut count, and Buchholz and SB with the
        # Article 16.4 dummy uncapped - C.07 as it stood from 1 August 2024,
        # which is what SWAR v6.49+ implements ("a dummy that concluded the
        # tournament with the same number of points as the participant";
        # the 16.4.1 and 16.4.2 caps are new in the 2026 text). Only the
        # draw-per-round cap can be lifted this way (a round count no event
        # reaches); the forfeit cap stays.
        alt_codes = ["BH", "BH/C1", "BH/C2", "BH/M1", "SB"]

        alt =
          if event.predetermined? do
            {:ok, v} = Ainalrami.Tiebreaks.compute(event, ["SB"])
            {:ok, u} = Ainalrami.Tiebreaks.compute(uncapped(event), ["SB"])
            %{capped: v, uncapped: u}
          else
            {:ok, v} = Ainalrami.Tiebreaks.compute(event, alt_codes)
            {:ok, u} = Ainalrami.Tiebreaks.compute(uncapped(event), alt_codes)
            %{capped: v, uncapped: u}
          end

        rows =
          for p <- players do
            e = by_ni[p.ni]

            codes =
              for {code, i} <- Enum.with_index(ties_codes), code != 0 do
                op = @op_codes[code]
                stored = Enum.at(stored_ties[p.ni], i)

                ours =
                  cond do
                    op == nil -> :unmapped
                    op not in effective -> {:dropped, dropped_reason(dropped, op)}
                    true -> e.tiebreaks[op]
                  end

                %{
                  slot: i,
                  code: code,
                  op: op,
                  swar: scale(code, stored),
                  model: scale(code, Enum.at(model_ties[p.ni], i)),
                  ours: ours
                }
              end

            %{
              ni: p.ni,
              name: String.trim(p.name || ""),
              rank_seed: p.rank,
              cat: if(t.cat_separes != 0, do: max(p.cat_index, 1), else: 0),
              # The standings SWAR prints: CalculLeClassement over the stored
              # values. The stored `Class` is the same thing when the file
              # was saved after a ranking with tie-breaks; after a pairing it
              # is SWAR's tie-break-free pre-pairing order instead
              # (`SwarView.cpp` `CalculLeClassement(FALSE)`), so it is only
              # kept for the report.
              swar_class: self_order[p.ni],
              stored_class: p.class,
              swar_points: p.points / 4,
              swar_total: totals[p.ni] / 4,
              extra: p.extra_pts / 4,
              our_rank: e.rank,
              our_points: e.points,
              our_score: Standings.rank_score(e, tournament),
              place: places[e.player.id],
              de_pos: de_pos[e.player.id],
              codes: codes,
              player: p,
              entry: e
            }
          end

        rows = within_category_ranks(rows)

        value_diffs =
          for row <- rows,
              c <- row.codes,
              is_number(c.ours),
              not same_value?(c),
              do: {row, c}

        swar_order = Enum.sort_by(rows, &{&1.cat, &1.swar_class})

        pairs =
          for {a, ia} <- Enum.with_index(swar_order),
              {b, ib} <- Enum.with_index(swar_order),
              ia < ib,
              a.cat == b.cat,
              a.our_cat_rank > b.our_cat_rank,
              do: {a, b}

        pair_causes =
          Enum.map(pairs, fn {a, b} -> {a, b, pair_cause(a, b, ctx, alt, tournament)} end)

        Map.merge(base, %{
          status: :compared,
          data: summary(data),
          warnings: warnings,
          finished?: finished?,
          last_round: ctx.last,
          op_completed: completed,
          extra_points_counted?: extra?,
          rank_diffs_as_imported: if(t.cat_separes == 0, do: rank_diffs_as_imported, else: nil),
          cat_separes: t.cat_separes != 0,
          elo_used: t.elo_used,
          op_tiebreaks: tournament.tiebreaks,
          op_effective: effective,
          op_dropped: dropped,
          op_pairing_system: tournament.pairing_system,
          predetermined?: event.predetermined?,
          points_reproduced?: points_reproduced?,
          ties_mismatch: ties_mismatch,
          swar_consistent?: swar_consistent?,
          rows: rows,
          rank_diffs: Enum.count(rows, &(&1.our_cat_rank != &1.swar_class)),
          value_diffs:
            Enum.map(value_diffs, fn {row, c} ->
              {row, c, classify_value(row, c, ctx, alt, tournament)}
            end),
          values_compared: Enum.count(for row <- rows, c <- row.codes, is_number(c.ours), do: 1),
          pairs: pair_causes
        })
    end
  end

  defp dropped_reason(dropped, op) do
    case List.keyfind(dropped, op, 0) do
      {_, reason} -> reason
      nil -> :not_in_list
    end
  end

  defp c07(event, entries, tournament, effective) do
    codes =
      effective
      |> Enum.filter(&Map.has_key?(AinalramiBridge.codes(), &1))
      |> Enum.reject(&(event.predetermined? and &1 in ~w(BH BHC1 BHC2 MBH)))
      |> Enum.map(&AinalramiBridge.c07_code/1)

    score = Map.new(entries, &{&1.player.id, Standings.rank_score(&1, tournament) * 1.0})

    case Ainalrami.Tiebreaks.rank(event, codes, score: score) do
      {:ok, standings} ->
        {Map.new(standings, &{&1.id, &1.rank}),
         Map.new(standings, &{&1.id, Map.get(&1.values, "DE")})}

      {:error, _} ->
        {%{}, %{}}
    end
  end

  defp within_category_ranks(rows) do
    rows
    |> Enum.group_by(& &1.cat)
    |> Enum.flat_map(fn {_cat, group} ->
      group
      |> Enum.sort_by(& &1.our_rank)
      |> Enum.with_index(1)
      |> Enum.map(fn {row, i} -> Map.put(row, :our_cat_rank, i) end)
    end)
  end

  defp scale(code, v) when code in @quarter_codes and is_integer(v), do: v / 4
  defp scale(_code, v), do: v

  # SWAR's DE is -1 where it does not apply; OpenPairings shows 0.0 there.
  defp same_value?(%{code: 8, swar: s, ours: o}) when s < 0, do: o == 0.0
  defp same_value?(%{swar: s, ours: o}), do: abs(s - o) < 1.0e-6

  # ------------------------------------------------------ rank differences

  # Why a pair is ordered differently: the first criterion of SWAR's list on
  # which the two programs stop agreeing.
  defp pair_cause(a, b, ctx, alt, tournament) do
    cond do
      a.swar_total != a.our_score or b.swar_total != b.our_score ->
        {:score, score_detail(a, b, ctx)}

      true ->
        case walk(Enum.zip(a.codes, b.codes), a, b, ctx, alt, tournament) do
          # SWAR ranks each category on its own (`CatSepares`), so its tied
          # groups - and its direct encounter - stop at the category;
          # OpenPairings ranks the whole field.
          {:de, _, _} when ctx.t.cat_separes != 0 -> :de_categories_separate
          cause -> cause
        end
    end
  end

  defp score_detail(a, b, ctx) do
    [a, b]
    |> Enum.filter(&(&1.swar_total != &1.our_score))
    |> Enum.map(fn r ->
      through_horizon =
        r.entry.games
        |> Enum.filter(&(&1.round <= ctx.last))
        |> Enum.map(& &1.points)
        |> Enum.sum()

      cond do
        r.swar_points != r.our_points and abs(through_horizon - r.swar_points) < 1.0e-6 ->
          :horizon_points_for_unplayed_round

        r.swar_points == r.our_points and r.extra != 0 ->
          :extra_points_not_counted

        r.swar_points != r.our_points ->
          :points_differ

        true ->
          :special_points
      end
    end)
    |> Enum.uniq()
  end

  defp walk([], a, b, _ctx, _alt, _t) do
    if a.place != nil and a.place == b.place,
      do: {:fallback, :shared_c07_place},
      else: {:fallback, :op_order_after_list}
  end

  defp walk([{ca, cb} | rest], a, b, ctx, alt, t) do
    s = cmp(ca.swar, cb.swar)

    o =
      cond do
        ca.op == "DE" and is_number(ca.ours) -> cmp_de(a.de_pos, b.de_pos)
        is_number(ca.ours) -> cmp(ca.ours, cb.ours)
        true -> :absent
      end

    cond do
      o == :absent and s == 0 ->
        walk(rest, a, b, ctx, alt, t)

      o == :absent ->
        {:list, ca.code, ca.ours}

      s == o and s == 0 ->
        walk(rest, a, b, ctx, alt, t)

      s == o ->
        # Both programs order the pair the same way on this criterion;
        # anything that follows cannot be the cause.
        {:agree_then, ca.code}

      ca.op == "DE" ->
        {:de, s, o}

      true ->
        tags =
          [{a, ca}, {b, cb}]
          |> Enum.reject(fn {_r, c} -> same_value?(c) end)
          |> Enum.flat_map(fn {r, c} -> classify_value(r, c, ctx, alt, t) end)
          |> Enum.uniq()

        {:value, ca.code, tags}
    end
  end

  defp cmp(x, y) when x > y, do: 1
  defp cmp(x, y) when x < y, do: -1
  defp cmp(_, _), do: 0

  # A lower DE position is better; nil (not tied, or DE not reached) is level.
  defp cmp_de(x, y) when is_integer(x) and is_integer(y), do: cmp(y, x)
  defp cmp_de(_, _), do: 0

  # ------------------------------------------------------ value differences

  @doc false
  def classify_value(row, c, ctx, alt, _t) do
    p = row.player
    rounds = Enum.take(p.rounds, ctx.last)

    tags =
      if(abs(c.model - c.swar) > 1.0e-6, do: [not_reproduced(ctx.version)], else: []) ++
        if(ctx.last < 2, do: [:swar_no_tiebreaks_before_round_2], else: []) ++
        if(ctx.op_completed != ctx.last, do: [{:horizon, ctx.last, ctx.op_completed}], else: [])

    own_unplayed = unplayed_kinds(rounds)
    opp_unplayed? = opp_unplayed?(p, ctx)

    specific =
      case c.code do
        code when code in 1..5 ->
          buchholz_tags(row, c, ctx, alt, own_unplayed, opp_unplayed?)

        6 ->
          uncapped_sb = alt_get(alt, :uncapped, "SB", row.entry.player.id)

          cond do
            is_number(uncapped_sb) and abs(uncapped_sb - c.swar) < 1.0e-6 ->
              [:dummy_uncapped_c07_2024]

            # TieSonneborn adds the player's own score for a +BYE in every
            # event type; in a round robin C.07 15.2 makes the free round
            # no element of the sum at all.
            Model.robin?(ctx.t.type) and Enum.any?(rounds, &(&1.result == 0x0040)) ->
              [:rr_free_round_in_sb]

            true ->
              sb_tags(p, ctx, own_unplayed, opp_unplayed?)
          end

        7 ->
          if own_unplayed != [], do: [{:ps_unplayed, own_unplayed}], else: [:ps_other]

        9 ->
          koya_tags(p, ctx)

        10 ->
          if Enum.any?(rounds, &(&1.result == 0x0040)),
            do: [:win_excludes_pab],
            else: [:win_other]

        12 ->
          aro_tags(p, ctx)

        13 ->
          aro_tags(p, ctx) ++ if(own_unplayed != [], do: [:aroc1_no_cut_after_unplayed], else: [])

        14 ->
          if Enum.any?(
               rounds,
               &(&1.color == -1 and ((&1.result &&& 0x000F) != 0 or &1.result == 0))
             ),
             do: [:bpg_counts_forfeits],
             else: [:bpg_other]

        8 ->
          [:de_value]

        _ ->
          [:other]
      end

    tags ++ specific
  end

  # The port is of SWAR v6.65; Buchholz and SB were rewritten in v6.49
  # ("v6.49 : nouvelle manière de calculer (FIDE)"), and v7's source is not
  # available.
  defp not_reproduced(version) when version < "v6.49", do: :swar_pre_v649_algorithm
  defp not_reproduced(version) when version >= "v7", do: :swar_v7_algorithm
  defp not_reproduced(_version), do: :swar_value_not_reproduced

  defp unplayed_kinds(rounds) do
    rounds
    |> Enum.flat_map(fn r ->
      cond do
        r.table == 0x4000 -> [:absent]
        r.table == 0x2000 -> [:withdrawn]
        (r.result &&& 0x00F0) != 0 -> [:bye]
        (r.result &&& 0x000F) != 0 -> [:forfeit]
        true -> []
      end
    end)
    |> Enum.uniq()
  end

  defp opp_unplayed?(p, ctx) do
    Enum.any?(Enum.take(p.rounds, ctx.last), fn r ->
      case ctx.by_ni[r.advers] do
        nil -> false
        opp -> unplayed_kinds(Enum.take(opp.rounds, ctx.last)) != []
      end
    end)
  end

  defp uncapped(event), do: %{event | cap_rounds: :announced, total_rounds: 10_000}

  defp alt_get(alt, cap, code, id) do
    case get_in(alt, [cap, code]) do
      %{} = map -> Map.get(map, id)
      _ -> nil
    end
  end

  defp buchholz_tags(row, c, ctx, alt, own_unplayed, opp_unplayed?) do
    nominal = %{2 => 1, 3 => 2, 4 => 1, 5 => 2}[c.code] || 0
    swar_cuts = min(div(ctx.last - 1, 4), nominal)
    id = row.entry.player.id
    absent? = :absent in own_unplayed

    code_for = fn
      0 -> "BH"
      1 when c.code in [2, 3] -> "BH/M1"
      1 -> "BH/C1"
      2 -> "BH/C2"
      _ -> nil
    end

    matches? = fn v -> is_number(v) and abs(v - c.swar) < 1.0e-6 end

    # The first combination of SWAR's documented departures that turns
    # OpenPairings' number into SWAR's.
    explained =
      for cuts <- Enum.uniq(if(absent? and c.code in 2..5, do: [0, swar_cuts], else: [swar_cuts])),
          cap <- [:capped, :uncapped],
          matches?.(alt_get(alt, cap, code_for.(cuts), id)) do
        if(cuts < nominal and cuts == swar_cuts,
          do: [{:cut_scaled_by_rounds, swar_cuts, nominal}],
          else: []
        ) ++
          if(cuts == 0 and absent? and c.code in 2..5, do: [:cut_suppressed_for_absent], else: []) ++
          if(cap == :uncapped, do: [:dummy_uncapped_c07_2024], else: [])
      end
      |> List.first()

    # TieBucholtz collects the values to cut from the opponents only; the
    # own-unplayed-round dummy is added afterwards and never cut, even when it
    # is the least significant value (14.1).
    opponent_values =
      for r <- Enum.take(row.player.rounds, ctx.last),
          (r.table &&& 0x7000) == 0,
          v = Map.get(ctx.c07_adjusted, r.advers),
          v != nil,
          do: v

    our_bh = alt_get(alt, :capped, "BH", id)

    skips_dummy? =
      c.code == 4 and swar_cuts == 1 and opponent_values != [] and is_number(our_bh) and
        Enum.any?(own_unplayed, &(&1 in [:bye, :forfeit])) and
        matches?.(our_bh - Enum.min(opponent_values))

    cond do
      explained != nil ->
        explained

      skips_dummy? ->
        [:swar_cut_skips_dummy]

      true ->
        base =
          cond do
            c.code in 2..5 and absent? ->
              [:cut_suppressed_for_absent]

            c.code in 2..5 and swar_cuts < nominal ->
              [{:cut_scaled_by_rounds, swar_cuts, nominal}]

            true ->
              []
          end

        specific = unplayed_tags(row.player, ctx)

        base ++
          if specific != [] do
            specific
          else
            if(own_unplayed != [], do: [{:bh_own_unplayed, own_unplayed}], else: []) ++
              if(opp_unplayed?, do: [:bh_opponent_unplayed], else: []) ++
              if(own_unplayed == [] and not opp_unplayed?, do: [:bh_unexplained], else: [])
          end
    end
  end

  # SWAR's specific departures from Article 16 that reach this player's
  # Buchholz or SB, each checked against the record rather than assumed.
  defp unplayed_tags(p, ctx) do
    rounds = Enum.take(p.rounds, ctx.last)

    # TieBucholtz means to skip an opponent who forfeited against this
    # player, but compares that opponent's forfeit opponent with this
    # player's Rank rather than Ni - so unless the two numbers happen to be
    # equal the opponent's score is counted as if the game had been played,
    # on top of the own-score dummy for the same round.
    forfeit_counted? =
      Enum.any?(rounds, fn r ->
        opp = ctx.by_ni[r.advers]

        (r.result &&& 0x000F) != 0 and (r.table &&& 0x7000) == 0 and opp != nil and
          not Enum.any?(
            Enum.take(opp.rounds, ctx.last),
            &((&1.result &&& 0x000F) != 0 and &1.advers == p.rank)
          )
      end)

    # An opponent whose adjusted score (16.3) SWAR computes differently:
    # getBuchNonJouer counts trailing forfeit LOSSES as draws, where 16.3.2
    # covers requested byes only (a forfeit loss is 16.2.4, "as awarded").
    adjusted_diff =
      rounds
      |> Enum.map(& &1.advers)
      |> Enum.uniq()
      |> Enum.filter(fn ni ->
        swar = Map.get(ctx.adjusted, ni)
        ours = Map.get(ctx.c07_adjusted, ni)
        swar != nil and ours != nil and abs(swar / 4 - ours) > 1.0e-6
      end)

    trailing_ff? =
      Enum.any?(adjusted_diff, fn ni ->
        opp = ctx.by_ni[ni]

        tail =
          opp.rounds
          |> Enum.take(ctx.last)
          |> Enum.reverse()
          |> Enum.take_while(
            &((&1.result &&& 0x000F) != 0 or &1.table == 0x4000 or &1.result == 0)
          )

        Enum.any?(tail, &(&1.result == 0x0001))
      end)

    # 16.4.1 (new in 2026): a forfeit's dummy may not exceed the scheduled
    # opponent's adjusted score. SWAR's dummy is the player's own score.
    own = Map.get(ctx.points, p.ni, 0) / 4

    forfeit_capped? =
      Enum.any?(rounds, fn r ->
        adj = Map.get(ctx.c07_adjusted, r.advers)
        (r.result &&& 0x000F) != 0 and adj != nil and adj < own
      end)

    # The same comparison the other way round: an opponent the player DID
    # play is skipped when that opponent forfeited against whoever's Ni
    # equals this player's Rank.
    opponent_skipped? =
      p.rank != p.ni and
        Enum.any?(rounds, fn r ->
          opp = ctx.by_ni[r.advers]

          (r.table &&& 0x7000) == 0 and (r.result &&& 0x000F) == 0 and opp != nil and
            Enum.any?(
              Enum.take(opp.rounds, ctx.last),
              &((&1.result &&& 0x000F) != 0 and &1.advers == p.rank)
            )
        end)

    if(forfeit_counted?, do: [:swar_counts_forfeit_opponent], else: []) ++
      if(opponent_skipped?, do: [:swar_skips_played_opponent], else: []) ++
      if(forfeit_capped?, do: [:forfeit_dummy_cap_c07_2026], else: []) ++
      cond do
        trailing_ff? -> [:swar_trailing_forfeit_loss_as_draw]
        adjusted_diff != [] -> [:opponent_adjusted_score_differs]
        true -> []
      end
  end

  defp sb_tags(p, ctx, own_unplayed, opp_unplayed?) do
    odd =
      Enum.any?(Enum.take(p.rounds, ctx.last), fn r ->
        opp = ctx.by_ni[r.advers]

        opp && (r.result &&& 0x2000) != 0 && rem(Map.get(ctx.points, opp.ni, 0), 2) == 1
      end)

    specific =
      (unplayed_tags(p, ctx) -- [:swar_counts_forfeit_opponent, :swar_skips_played_opponent]) ++
        sb_opponent_tags(p, ctx)

    if(own_unplayed != [], do: [{:sb_own_unplayed, own_unplayed}], else: []) ++
      specific ++
      if(opp_unplayed? and specific == [], do: [:sb_opponent_unplayed], else: []) ++
      if(odd, do: [:sb_truncates_quarter], else: []) ++
      if(own_unplayed == [] and not opp_unplayed? and not odd, do: [:sb_unexplained], else: [])
  end

  # TieSonneborn does not use the adjusted score TieBucholtz uses: it takes
  # the opponent's plain score plus getSonnebornNonJouer's correction, which
  # counts trailing absences only and returns nothing for exactly one - so an
  # opponent absent in the last round only is not adjusted (16.2.5 makes that
  # a draw), and a trailing forfeit loss is not either.
  defp sb_opponent_tags(p, ctx) do
    diffs =
      for r <- Enum.take(p.rounds, ctx.last),
          (r.result &&& 0x6200) != 0,
          opp = ctx.by_ni[r.advers],
          opp != nil,
          ours = Map.get(ctx.c07_adjusted, opp.ni),
          ours != nil,
          swar = (Map.get(ctx.points, opp.ni, 0) + Model.sb_correction(opp, ctx)) / 4,
          abs(swar - ours) > 1.0e-6,
          do: opp

    single_last? =
      Enum.any?(diffs, fn opp ->
        tail =
          opp.rounds
          |> Enum.take(ctx.last)
          |> Enum.reverse()
          |> Enum.take_while(&(&1.table == 0x4000))

        length(tail) == 1
      end)

    cond do
      diffs == [] -> []
      single_last? -> [:swar_sb_single_last_round_absence]
      true -> [:swar_sb_opponent_score_differs]
    end
  end

  defp koya_tags(p, ctx) do
    rounds = Enum.take(p.rounds, ctx.last)

    cond do
      Enum.any?(rounds, &((&1.result &&& 0x000F) != 0)) -> [:koya_forfeit]
      Model.robin?(ctx.t.type) -> [:koya_rr_threshold]
      true -> [:koya_other]
    end
  end

  defp aro_tags(p, ctx) do
    unrated_opp? =
      Enum.any?(Enum.take(p.rounds, ctx.last), fn r ->
        case ctx.by_ni[r.advers] do
          nil -> false
          opp -> Model.elo(opp, ctx.t) == 0
        end
      end)

    if unrated_opp?, do: [:aro_excludes_unrated], else: [:aro_rating_source]
  end

  # ---------------------------------------------------------------- report

  def cause_label({:score, details}), do: "score: " <> Enum.map_join(details, ", ", &to_string/1)

  def cause_label({:list, code, {:dropped, reason}}),
    do: "#{@swar_names[code]} not applied by OpenPairings (#{reason})"

  def cause_label({:list, code, :unmapped}), do: "#{@swar_names[code]} has no OpenPairings code"

  def cause_label({:value, code, tags}),
    do: "#{@swar_names[code]} value: " <> Enum.map_join(tags, ", ", &tag/1)

  def cause_label(:de_categories_separate),
    do:
      "direct encounter: SWAR ranks each category separately (its tied groups stop at the category); OpenPairings ranks one field"

  def cause_label({:de, _s, _o}),
    do:
      "direct encounter: C.07 Article 6 orders a group SWAR's all-met DE leaves level (or the reverse)"

  def cause_label({:agree_then, code}),
    do: "ordered alike on #{@swar_names[code]} (should not happen)"

  def cause_label({:fallback, :shared_c07_place}),
    do:
      "level after the whole list: SWAR orders by seed rank, OpenPairings by rating/name (C.07 shares the place)"

  def cause_label({:fallback, other}), do: "level on SWAR's list: #{other}"

  def tag({:horizon, swar, ours}),
    do:
      "horizon: SWAR counts #{swar} rounds (any result in), OpenPairings #{ours} (every result in)"

  def tag({:cut_scaled_by_rounds, n, nominal}),
    do: "SWAR cuts #{n} not #{nominal} (cut count scaled by rounds played)"

  def tag({kind, list}) when is_list(list), do: "#{kind}(#{Enum.join(list, "+")})"

  def tag(:dummy_uncapped_c07_2024),
    do: "SWAR's 16.4 dummy is the player's own score, uncapped (C.07 2024; 2026 caps it)"

  def tag(:swar_cut_skips_dummy),
    do:
      "SWAR's Cut-1 never cuts the own-unplayed-round dummy, even when it is the lowest value (14.1)"

  def tag(:swar_skips_played_opponent),
    do:
      "SWAR leaves out a PLAYED opponent who forfeited against the player numbered like this player's Rank (Rank/Ni mix-up in TieBucholtz)"

  def tag(:swar_sb_single_last_round_absence),
    do:
      "SWAR's SB does not adjust an opponent absent in the last round only (16.2.5/16.3.2: a draw; SWAR's own Buchholz does)"

  def tag(:swar_sb_opponent_score_differs),
    do:
      "SWAR's SB uses the opponent's plain score plus trailing absences, not the 16.3 adjusted score"

  def tag(:rr_free_round_in_sb),
    do:
      "SWAR's SB counts a round robin's free round at the player's own score (C.07 15.2: not an element)"

  def tag(:swar_pre_v649_algorithm),
    do: "file saved by SWAR before v6.49 (its older Buchholz/SB, not ported)"

  def tag(:swar_v7_algorithm),
    do: "file saved by SWAR v7 (changed after the v6.65 source, not ported)"

  def tag(:swar_value_not_reproduced), do: "SWAR's stored value not reproduced by the v6.65 port"
  def tag(:cut_suppressed_for_absent), do: "SWAR cuts nothing for a player with an absence"

  def tag(:swar_counts_forfeit_opponent),
    do:
      "SWAR counts a forfeit opponent's score as if played, on top of the dummy (Rank/Ni mix-up in TieBucholtz)"

  def tag(:swar_trailing_forfeit_loss_as_draw),
    do:
      "SWAR's adjusted score counts an opponent's trailing forfeit losses as draws (16.3.2 covers requested byes only)"

  def tag(:forfeit_dummy_cap_c07_2026),
    do:
      "C.07 2026 caps a forfeit's dummy at the opponent's adjusted score (16.4.1); SWAR uses the own score (2024)"

  def tag(:opponent_adjusted_score_differs), do: "an opponent's adjusted score (16.3) differs"

  def tag(:win_excludes_pab),
    do: "SWAR's Wins leaves out a pairing-allocated bye (C.07 7.1 counts it)"

  def tag(:bpg_counts_forfeits),
    do:
      "SWAR's Black games counts a black pairing whatever its result - a forfeit, or none yet (C.07 7.3: played games)"

  def tag(:aro_excludes_unrated),
    do: "SWAR's ARO skips unrated opponents (C.07 Article 10 drops ARO)"

  def tag(:de_value), do: "direct encounter number (SWAR: all-met groups only)"
  def tag(:swar_no_tiebreaks_before_round_2), do: "SWAR computes no tie-breaks before round 2"
  def tag(other), do: to_string(other)

  def main(argv) do
    {opts, paths, _} = OptionParser.parse(argv, strict: [out: :string, allow_321: :boolean])
    files = files(paths)
    if files == [], do: Mix.raise("no .swar files under #{inspect(paths)}")

    db = setup_db()

    try do
      {results, _seen} =
        Enum.map_reduce(files, %{}, fn f, seen ->
          r =
            try do
              analyse(f, opts)
            rescue
              e ->
                %{
                  file: f,
                  sha: nil,
                  status: :crashed,
                  reason: Exception.format(:error, e, __STACKTRACE__)
                }
            end

          case r.sha && seen[r.sha] do
            nil ->
              {r, Map.put(seen, r.sha, f)}

            first ->
              {%{
                 file: f,
                 sha: r.sha,
                 status: :duplicate,
                 reason: "same bytes as #{Path.basename(first)}"
               }, seen}
          end
        end)

      print_summary(results)
      if opts[:out], do: write_report(results, opts[:out])
    after
      Repo.stop()
      for suffix <- ["", "-wal", "-shm"], do: File.rm(db <> suffix)
    end
  end

  defp print_summary(results) do
    by_status = Enum.group_by(results, & &1.status)

    IO.puts(
      "\n#{length(results)} files: " <>
        Enum.map_join(by_status, ", ", fn {s, l} -> "#{s} #{length(l)}" end)
    )

    for r <- Map.get(by_status, :compared, []) do
      d = r.data

      IO.puts(
        "#{Path.basename(r.file)} | #{d.type}, #{d.players}p, #{r.last_round}/#{d.rounds}r#{if r.finished?, do: "", else: " UNFINISHED"}" <>
          " | SWAR self-consistent #{r.swar_consistent?}, port points #{r.points_reproduced?}, port ties off #{length(r.ties_mismatch)}" <>
          " | ranks differ #{r.rank_diffs}/#{d.players}, values differ #{length(r.value_diffs)}/#{r.values_compared}, pairs #{length(r.pairs)}"
      )
    end

    for r <- results,
        r.status != :compared,
        do: IO.puts("  #{r.status}: #{Path.basename(r.file)} - #{r[:reason]}")

    IO.puts("")
    Enum.each(totals(results), &IO.puts/1)
  end

  # Agreement, finished events apart from the rest: a file saved mid-event
  # is compared too, but SWAR's horizon rule and its pre-pairing `Class`
  # make those numbers a different question.
  def totals(results) do
    compared = Enum.filter(results, &(&1.status == :compared))

    for {title, list} <- [
          {"finished", Enum.filter(compared, & &1.finished?)},
          {"unfinished", Enum.reject(compared, & &1.finished?)}
        ] do
      players = Enum.sum(Enum.map(list, & &1.data.players))
      rank_diffs = Enum.sum(Enum.map(list, & &1.rank_diffs))
      values = Enum.sum(Enum.map(list, & &1.values_compared))
      value_diffs = Enum.sum(Enum.map(list, &length(&1.value_diffs)))
      clean = Enum.count(list, &(&1.rank_diffs == 0))

      "#{title}: #{length(list)} events (#{clean} with identical ranks), #{players} players, " <>
        "ranks equal #{players - rank_diffs}/#{players}, tie-break values equal #{values - value_diffs}/#{values}"
    end
  end

  defp write_report(results, dir) do
    File.mkdir_p!(dir)
    compared = Enum.filter(results, &(&1.status == :compared))

    {finished, unfinished} = Enum.split_with(compared, & &1.finished?)

    pair_causes = fn list ->
      causes(list, fn r -> Enum.map(r.pairs, fn {_a, _b, c} -> cause_label(c) end) end)
    end

    value_causes = fn list ->
      causes(list, fn r ->
        Enum.map(r.value_diffs, fn {_row, c, tags} ->
          "#{@swar_names[c.code]}: " <> Enum.map_join(tags, ", ", &tag/1)
        end)
      end)
    end

    md = [
      "# SWAR re-rank report\n\n",
      Enum.map(totals(results), &"- #{&1}\n"),
      "\n",
      "| file | type | players | rounds | finished | SWAR self-consistent | port reproduces | tie-breaks (SWAR) | OpenPairings list | ranks differ | values differ | discordant pairs |\n",
      "|---|---|---|---|---|---|---|---|---|---|---|---|\n",
      for r <- compared do
        d = r.data

        "| #{Path.basename(r.file)} | #{d.type} | #{d.players} | #{r.last_round}/#{d.rounds} | #{r.finished?} | #{r.swar_consistent?} | points #{r.points_reproduced?}, ties off #{length(r.ties_mismatch)} | #{Enum.join(d.tiebreaks, ", ")} | #{Enum.join(r.op_effective, " ")}#{if r.op_dropped != [], do: " (dropped: #{inspect(r.op_dropped)})", else: ""} | #{r.rank_diffs} | #{length(r.value_diffs)}/#{r.values_compared} | #{length(r.pairs)} |\n"
      end,
      "\n## Not compared\n\n",
      for r <- results, r.status != :compared do
        "- #{Path.basename(r.file)}: #{r.status} - #{String.slice(to_string(r[:reason]), 0, 300)}\n"
      end,
      for {title, list} <- [{"finished events", finished}, {"unfinished events", unfinished}] do
        [
          "\n## Rank-difference causes, #{title} (discordant pairs)\n\n",
          for {label, n, files} <- pair_causes.(list) do
            "- **#{n}** #{label} - #{Enum.map_join(files, "; ", fn {f, k} -> "#{f} (#{k})" end)}\n"
          end,
          "\n## Value-difference causes, #{title}\n\n",
          for {label, n, files} <- value_causes.(list) do
            "- **#{n}** #{label} - #{Enum.map_join(files, "; ", fn {f, k} -> "#{f} (#{k})" end)}\n"
          end
        ]
      end,
      "\n## Per event\n\n",
      Enum.map(compared, &event_md/1)
    ]

    File.write!(Path.join(dir, "report.md"), md)

    json =
      Enum.map(results, fn r ->
        r
        |> Map.drop([:rows, :pairs, :value_diffs])
        |> Map.update(:op_dropped, [], fn l -> Enum.map(l, fn {c, why} -> [c, why] end) end)
        |> Map.update(:ties_mismatch, [], fn l -> Enum.map(l, &Tuple.to_list/1) end)
        |> Map.put(
          :pairs,
          Enum.map(Map.get(r, :pairs, []), fn {a, b, c} -> [a.name, b.name, cause_label(c)] end)
        )
        |> Map.put(
          :value_diffs,
          Enum.map(Map.get(r, :value_diffs, []), fn {row, c, tags} ->
            [row.name, @swar_names[c.code], c.swar, c.ours, c.model, Enum.map(tags, &tag/1)]
          end)
        )
      end)

    File.write!(Path.join(dir, "report.json"), Jason.encode_to_iodata!(json, pretty: true))
    IO.puts("report: #{Path.join(dir, "report.md")}")
  end

  defp causes(list, labels) do
    list
    |> Enum.flat_map(fn r -> Enum.map(labels.(r), &{&1, Path.basename(r.file)}) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {label, files} -> {label, length(files), Enum.frequencies(files)} end)
    |> Enum.sort_by(&(-elem(&1, 1)))
  end

  defp event_md(r) do
    d = r.data

    rows =
      r.rows
      |> Enum.filter(fn row ->
        row.our_cat_rank != row.swar_class or
          Enum.any?(row.codes, &(is_number(&1.ours) and not same_value?(&1)))
      end)
      |> Enum.sort_by(&{&1.cat, &1.swar_class})

    [
      "### #{Path.basename(r.file)}\n\n",
      "#{d.name} - #{d.type}, #{d.version}, #{d.players} players, #{r.last_round}/#{d.rounds} rounds, ",
      "SWAR list: #{Enum.join(d.tiebreaks, ", ")}; OpenPairings: #{inspect(r.op_tiebreaks)} effective #{inspect(r.op_effective)}, pairing_system #{r.op_pairing_system}",
      if(r.cat_separes, do: ", categories ranked separately", else: ""),
      "\n\n",
      if(r.warnings != [], do: "Import warnings: #{length(r.warnings)}\n\n", else: ""),
      if rows == [] do
        "All ranks and values agree.\n\n"
      else
        [
          "| SWAR | ours | place | player | pts SWAR/ours | " <>
            Enum.map_join(hd(r.rows).codes, " | ", &"#{@swar_names[&1.code]} SWAR/ours/port") <>
            " |\n",
          "|---|---|---|---|---|" <>
            Enum.map_join(hd(r.rows).codes, "", fn _ -> "---|" end) <> "\n",
          for row <- rows do
            "| #{row.swar_class} | #{row.our_cat_rank} | #{row.place} | #{row.name} | #{row.swar_total}/#{row.our_score} | " <>
              Enum.map_join(row.codes, " | ", fn c ->
                mark = if is_number(c.ours) and not same_value?(c), do: "**", else: ""
                "#{mark}#{fmt(c.swar)}/#{fmt(c.ours)}/#{fmt(c.model)}#{mark}"
              end) <> " |\n"
          end,
          "\n",
          for {a, b, c} <- r.pairs do
            "- #{a.name} (SWAR #{a.swar_class}) vs #{b.name} (SWAR #{b.swar_class}): #{cause_label(c)}\n"
          end,
          "\n"
        ]
      end
    ]
  end

  defp fmt(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 2)
  defp fmt({:dropped, why}), do: "dropped(#{why})"
  defp fmt(v), do: to_string(v)
end

unless System.get_env("SWAR_RERANK_LIB"), do: SwarRerank.main(System.argv())
