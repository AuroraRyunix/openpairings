defmodule PairingsEngine.TrfFlowValidationTest do
  @moduledoc """
  End-to-end validation of pairing -> results -> "Send" -> TRF for rating.

  Every tournament is driven only through the app's own context functions
  (the calls the LiveViews and the Export page make): create, players, late
  entries, withdrawals, announced absences, `Pairing.pair_next_round/2`,
  `update_pairing_result/3` (postponed games included, played later),
  `PostponedGames.send_rounds/4` with the Export page's own builder (the file
  for rating, `TrfExport.export/3` with `for: :rating`), and
  `PostponedGames.send_late_games/3` with `TrfExport.postponed_export/2`.

  Every file that was SENT is then checked against the database, with this
  file's own fixed-column reading of the `001` records and its own table of
  which stored result becomes which TRF code - never the app's builder:

    * every file holds only records: no column ruler, no `DDD` legend, no
      comment line (`###`), no `162` with `X`, and no `?` anywhere;
    * every stored game of the file's rounds is on both players' lines, in
      its round's column, opponent and colour and code right; nothing else is;
      a game sent while postponed is NOT PLAYED there, `0000 - Z` on both
      players' lines;
    * the two sides of every game mirror each other (1/0, =/=, +/-, W/L,
      D/D), and asymmetric codes are counted separately;
    * the points column adds up from the file's own point system (`162`
      when it is not 1/half/0);
    * `062`/`072`/`132`/`042`/`052` agree with the file;
    * across ALL files sent for one tournament, every rated game (1, 0, =)
      appears exactly once, and every game played after its round was sent
      unplayed appears exactly once, in a postponed-games file, and in no
      round report;
    * sending a sent round again, and the same late games again, is refused;
    * the files for rating that start at round 1 - the first one sent, and
      one of every round as it stands at the end - pass Ainalrami's own
      checker (`ainalrami -c`): every round re-paired and compared, the
      standings re-ranked. Where a game in the file was postponed, the
      pairing replay cannot agree (the engine paired around the game as the
      draw it then was, and a game not played in the file leaves both
      players out of their round), so only its standings check must pass.

  TRF_FLOW_COUNT (unset: skipped), TRF_FLOW_FIRST, TRF_FLOW_DUMP=dir,
  TRF_FLOW_BAKU_PCT (share of Baku-accelerated tournaments, default 15).
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias PairingsEngine.{Pairing, PostponedGames, Repo, Tournaments, TrfExport}

  @moduletag :trf_flow
  @moduletag capture_log: true

  if System.get_env("TRF_FLOW_COUNT") in [nil, ""] do
    @moduletag skip: "set TRF_FLOW_COUNT to run"
  end

  setup do
    handler = "trf-flow-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:pairings_engine, :pairing, :trf_built],
      &__MODULE__.capture/4,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  @doc false
  def capture(_event, _m, meta, _c), do: Process.put({:own_trf, meta.round}, meta.trf)

  @tag timeout: :infinity
  test "every file sent for rating says exactly what the tournament holds" do
    first = env_int("TRF_FLOW_FIRST", 1)
    count = env_int("TRF_FLOW_COUNT", 5)
    dump = System.get_env("TRF_FLOW_DUMP")
    if dump, do: File.mkdir_p!(dump)

    results =
      for seed <- first..(first + count - 1) do
        fn -> run_seed(seed, dump) end |> Task.async() |> Task.await(:infinity)
      end

    totals =
      Enum.reduce(results, %{}, fn r, acc -> Map.merge(acc, r.stats, fn _, a, b -> a + b end) end)

    failures = Enum.flat_map(results, & &1.failures)

    if dump = System.get_env("TRF_FLOW_DUMP"),
      do: File.write!(Path.join(dump, "failures.txt"), Enum.join(failures, "
"))

    IO.puts(
      "\nTRFFLOW tournaments=#{count} " <>
        Enum.map_join(Enum.sort(totals), " ", fn {k, v} -> "#{k}=#{v}" end) <>
        " failures=#{length(failures)}"
    )

    assert failures == [], Enum.join(Enum.take(failures, 5), "\n\n")
  end

  defp env_int(name, default) do
    case Integer.parse(System.get_env(name) || "") do
      {v, ""} -> v
      _ -> default
    end
  end

  defp chance(pct), do: :rand.uniform(100) <= pct
  defp between(lo, hi) when hi <= lo, do: lo
  defp between(lo, hi), do: lo + :rand.uniform(hi - lo + 1) - 1

  ## ---------- one tournament ----------

  defp run_seed(seed, dump) do
    owner = Sandbox.start_owner!(Repo, shared: false, ownership_timeout: 1_800_000)

    try do
      :rand.seed(:exsss, {seed, seed * 7919, seed * 104_729})
      st = play(seed)
      st = validate(st, dump)
      %{stats: st.stats, failures: st.failures}
    rescue
      e ->
        %{
          stats: %{crashed: 1},
          failures: ["seed #{seed}: crashed\n" <> Exception.format(:error, e, __STACKTRACE__)]
        }
    after
      Sandbox.stop_owner(owner)
    end
  end

  @systems [{1.0, 0.5, 0.0}, {1.0, 0.5, 0.0}, {1.0, 0.5, 0.0}, {3.0, 1.0, 0.0}, {2.0, 1.0, 0.0}]

  defp play(seed) do
    n = between(6, 36)
    rounds = between(4, 9) |> min(n - 1)
    {win, draw, loss} = Enum.random(@systems)
    postponed? = chance(60)
    # TRF_FLOW_BAKU_PCT raises (or lowers) the share of Baku-accelerated
    # tournaments; the draw itself is the same one, so the default run is
    # the run it always was.
    baku? = chance(env_int("TRF_FLOW_BAKU_PCT", 15))

    # Rounds spread over two or three months, so late games cross a rating
    # period now and then.
    start = Date.new!(2026, 8, between(1, 28))
    dates = for r <- 1..rounds, do: Date.add(start, (r - 1) * between(5, 12))

    {:ok, t} =
      Tournaments.create_tournament(%{
        "name" => "TrfFlow #{seed}",
        "type" => "swiss",
        "city" => "Pelt",
        "federation" => "BEL",
        "chief_arbiter" => "Arbiter, Test",
        "rounds_count" => rounds,
        "pairing_engine" => "ainalrami",
        "acceleration" => if(baku?, do: "baku", else: "none"),
        "points_win" => win,
        "points_draw" => draw,
        "points_loss" => loss,
        "bye_value" => win,
        "postponed_games" => postponed?,
        "start_date" => Date.to_iso8601(hd(dates)),
        "end_date" => Date.to_iso8601(List.last(dates)),
        "round_dates" => Enum.map(dates, &Date.to_iso8601/1),
        "fide_tournament_id" => "#{900_000 + seed}"
      })

    st = %{
      seed: seed,
      tid: t.id,
      rounds: rounds,
      dates: dates,
      postponed?: postponed?,
      next: 1,
      withdrawn: %{},
      sent_files: [],
      late_files: [],
      stats: %{},
      failures: []
    }

    st = Enum.reduce(1..n, st, fn _, acc -> add_player(acc, 1) end)

    # When the arbiter sends: after some rounds, sometimes twice mid-event.
    send_after = Enum.take_random(1..rounds, between(1, 3)) |> Enum.sort()

    st =
      Enum.reduce_while(1..rounds, st, fn r, acc ->
        acc = before_round(acc, r)

        # The Pairings page's confirmation of an older postponed game still
        # open - the only acknowledgement pairing asks for here.
        case Pairing.pair_next_round(Tournaments.get_tournament!(acc.tid),
               acknowledged: [:adjourned_older_round_open]
             ) do
          {:ok, round} ->
            acc = acc |> enter_results(round, r) |> play_late_games(r)
            acc = if r in send_after or r == rounds, do: send_now(acc, r), else: acc
            {:cont, bump(acc, :rounds)}

          {:error, reason} ->
            IO.puts("seed #{acc.seed} round #{r}: pairing stopped: #{inspect(reason, limit: 8)}")
            acc = send_now(acc, r - 1)
            {:halt, bump(acc, :halted)}
        end
      end)

    # After the event: every postponed game still open is played, then the
    # late games go out, one file per rating period.
    st = play_late_games(st, :all)
    send_late(st)
  end

  defp bump(st, key, by \\ 1), do: %{st | stats: Map.update(st.stats, key, by, &(&1 + by))}

  defp add_player(st, start_round) do
    i = st.next
    fide = if chance(15), do: 0, else: between(1000, 2600)

    {:ok, _p} =
      Tournaments.create_player(st.tid, %{
        "name" => "Player#{i}, S#{st.seed}",
        "fide_rating" => fide,
        "fide_id" => if(chance(85), do: 10_000_000 + st.seed * 100 + i),
        "federation" => Enum.random(~w(BEL BEL BEL NED FRA)),
        "sex" => Enum.random(~w(m m w)),
        "birth_year" => between(1950, 2015),
        "start_round" => start_round
      })

    %{st | next: i + 1}
  end

  defp active(st, r) do
    st.tid
    |> Tournaments.list_players()
    |> Enum.filter(&((&1.start_round || 1) <= r and not Map.has_key?(st.withdrawn, &1.id)))
  end

  defp before_round(st, r) do
    st =
      if r >= 2 and chance(25),
        do: add_player(st, Tournaments.next_start_round(st.tid)),
        else: st

    st =
      if r >= 2 and chance(20) and length(active(st, r)) > 6 do
        p = Enum.random(active(st, r))
        {:ok, _} = Tournaments.update_player(p, %{"status" => "withdrawn"})
        %{st | withdrawn: Map.put(st.withdrawn, p.id, r)}
      else
        st
      end

    if chance(35) and length(active(st, r)) > 6 do
      p = Enum.random(active(st, r))
      kept = String.split(p.absent_rounds || "", ",", trim: true)

      {:ok, _} =
        Tournaments.update_player(p, %{"absent_rounds" => Enum.join(kept ++ ["#{r}"], ",")})

      st
    else
      st
    end
  end

  @ack PostponedGames.acknowledgement_ids()

  defp enter_results(st, round, r) do
    round = Repo.preload(round, :pairings, force: true)

    Enum.reduce(round.pairings, st, fn p, acc ->
      if p.black_player_id && p.result in [nil, ""] do
        result = pick_result(acc)
        opts = [acknowledged: @ack, played_on: Enum.at(acc.dates, r - 1)]

        case Tournaments.update_pairing_result(p, result, opts) do
          {:ok, _} ->
            acc = bump(acc, :games)
            if result in ~w(* *W *B), do: Map.put(acc, :had_postponed, true), else: acc

          {:error, reason} ->
            fail(acc, "round #{r}: result #{result} refused: #{inspect(reason)}")
        end
      else
        acc
      end
    end)
  end

  defp pick_result(st) do
    cond do
      st.postponed? and chance(7) -> Enum.random(~w(* *W *B))
      chance(6) -> Enum.random(~w(1-0FF 0-1FF 0-0FF))
      chance(3) -> Enum.random(~w(1-0U 0-1U 1/2-1/2U))
      true -> Enum.random(~w(1-0 0-1 1/2-1/2 1-0 0-1))
    end
  end

  # Open postponed games get played: some during the event, all of them at
  # the end. The date played is some days after the round they belong to.
  defp play_late_games(%{postponed?: false} = st, _r), do: st

  defp play_late_games(st, r) do
    st.tid
    |> PostponedGames.open_games()
    |> Enum.filter(fn _ -> r == :all or chance(40) end)
    |> Enum.reduce(st, fn %{round: rn, pairing: p}, acc ->
      result = Enum.random(~w(1-0 0-1 1/2-1/2 1-0FF))
      played = Date.add(Enum.at(acc.dates, rn - 1), between(1, 30))
      opts = [acknowledged: @ack, played_on: played]

      case Tournaments.update_pairing_result(Repo.reload!(p), result, opts) do
        {:ok, _} -> bump(acc, :late_played)
        {:error, reason} -> fail(acc, "late game r#{rn}: #{result} refused: #{inspect(reason)}")
      end
    end)
  end

  # The Export page's "Send…": every round not yet sent up to `upto`.
  defp send_now(st, upto) when upto < 1, do: st

  defp send_now(st, upto) do
    t = Tournaments.get_tournament!(st.tid)
    sent = PostponedGames.sent_rounds(t)
    rounds = Enum.to_list(1..upto) -- sent

    if rounds == [] do
      st
    else
      meta = TrfExport.export_meta(t, Enum.join(rounds, ","))

      case PostponedGames.send_rounds(
             t,
             meta.rounds,
             fn fresh -> TrfExport.export(fresh, meta.rounds, for: :rating) end,
             acknowledged: [:round_sent_before]
           ) do
        {:ok, %{file: text}} ->
          st = %{st | sent_files: st.sent_files ++ [{meta.rounds, text}]}

          # Sending the same rounds again must be refused, building nothing.
          case PostponedGames.send_rounds(t, meta.rounds, fn f ->
                 TrfExport.export(f, meta.rounds, for: :rating)
               end) do
            {:error, {:already_sent, _}} ->
              bump(st, :resend_refused)

            other ->
              fail(st, "rounds #{inspect(meta.rounds)} sent twice: #{inspect(other, limit: 3)}")
          end

        {:error, reason} ->
          fail(st, "send of rounds #{inspect(rounds)} refused: #{inspect(reason)}")
      end
    end
  end

  defp send_late(%{postponed?: false} = st), do: st

  defp send_late(st) do
    t = Tournaments.get_tournament!(st.tid)

    periods =
      t
      |> PostponedGames.sendable_late_games()
      |> Enum.map(&PostponedGames.late_period/1)
      |> Enum.uniq()
      |> Enum.reject(&is_nil/1)

    st =
      Enum.reduce(periods, st, fn period, acc ->
        build = &TrfExport.postponed_export(&1, period: period)

        case PostponedGames.send_late_games(t, build) do
          {:ok, text, games, _receipt} ->
            acc = %{acc | late_files: acc.late_files ++ [{period, text, length(games)}]}

            case PostponedGames.send_late_games(t, build) do
              {:error, :nothing_to_send} ->
                bump(acc, :late_resend_refused)

              other ->
                fail(acc, "late games of #{period} sent twice: #{inspect(other, limit: 3)}")
            end

          {:error, reason} ->
            fail(acc, "late send #{period} refused: #{inspect(reason)}")
        end
      end)

    st
  end

  defp fail(st, message) do
    %{st | failures: st.failures ++ ["seed #{st.seed}: " <> message]} |> bump(:failed)
  end

  ## ---------- the checks ----------

  defp validate(st, dump) do
    t = Tournaments.get_tournament!(st.tid)
    players = Tournaments.list_players(st.tid)
    by_id = Map.new(players, &{&1.id, &1})
    games = stored_games(st.tid)

    st =
      Enum.reduce(st.sent_files, st, fn {rounds, text}, acc ->
        acc = maybe_dump(acc, dump, "r#{Enum.join(rounds, "-")}", text)
        check_report(acc, t, rounds, text, games, by_id)
      end)

    st =
      Enum.reduce(st.late_files, st, fn {period, text, n}, acc ->
        acc = maybe_dump(acc, dump, "late-#{period}", text)
        check_late(acc, text, n)
      end)

    st = check_once(st, games, by_id)
    st = check_against_engine_input(st, t, dump)
    check_with_engine(st, t, games, dump)
  end

  defp maybe_dump(st, nil, _tag, _text), do: st

  defp maybe_dump(st, dir, tag, text) do
    File.write!(Path.join(dir, "s#{st.seed}-#{tag}.trf"), text)
    st
  end

  # Every stored board, as the database holds it now.
  defp stored_games(tid) do
    import Ecto.Query

    Repo.all(
      from p in PairingsEngine.Tournaments.Pairing,
        join: r in PairingsEngine.Tournaments.Round,
        on: p.round_id == r.id,
        where: r.tournament_id == ^tid,
        select: %{
          round: r.number,
          white: p.white_player_id,
          black: p.black_player_id,
          result: p.result,
          finalised_open: p.finalised_open,
          played_on: p.played_on
        }
    )
  end

  # What this test expects on each side for a stored result.
  @codes %{
    "1-0" => {"1", "0"},
    "0-1" => {"0", "1"},
    "1/2-1/2" => {"=", "="},
    "1-0FF" => {"+", "-"},
    "0-1FF" => {"-", "+"},
    "0-0FF" => {"-", "-"},
    "1-0U" => {"W", "L"},
    "0-1U" => {"L", "W"},
    "1/2-1/2U" => {"D", "D"},
    "0-0" => {"0", "0"},
    "1/2-0" => {"=", "0"},
    "0-1/2" => {"0", "="}
  }

  @rated ~w(1 0 =)
  @mirror %{
    "1" => "0",
    "0" => "1",
    "=" => "=",
    "+" => "-",
    "-" => "+",
    "W" => "L",
    "L" => "W",
    "D" => "D"
  }

  # A double forfeit: both sides lose, unplayed.
  @both_lose [{"-", "-"}]

  defp parse_001(text) do
    for line <- String.split(text, ["\r\n", "\n"]),
        String.starts_with?(line, "001 "),
        into: %{} do
      rank = line |> String.slice(4, 4) |> String.trim() |> String.to_integer()

      blocks =
        line
        |> String.slice(91..-1//1)
        |> then(&String.pad_trailing(&1, round_up(String.length(&1))))
        |> chunk10()
        |> Enum.with_index(1)
        |> Map.new(fn {b, col} ->
          opp = b |> String.slice(0, 4) |> String.trim()

          {col,
           %{
             opp: if(opp in ["", "0000"], do: nil, else: String.to_integer(opp)),
             colour: b |> String.slice(5, 1) |> String.trim(),
             code: b |> String.slice(7, 1) |> String.trim()
           }}
        end)

      {rank,
       %{
         name: line |> String.slice(14, 33) |> String.trim(),
         rating: line |> String.slice(48, 4) |> String.trim(),
         points: line |> String.slice(80, 4) |> String.trim() |> parse_float(),
         place: line |> String.slice(85, 4) |> String.trim(),
         blocks: blocks
       }}
    end
  end

  defp round_up(len), do: div(len + 9, 10) * 10
  defp chunk10(""), do: []
  defp chunk10(s), do: [String.slice(s, 0, 10) | chunk10(String.slice(s, 10..-1//1))]

  defp parse_float(""), do: nil

  defp parse_float(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp header(text, code) do
    text
    |> String.split(["\r\n", "\n"])
    |> Enum.find_value(fn line ->
      if String.starts_with?(line, code <> " "), do: String.slice(line, 4..-1//1)
    end)
  end

  # TRF26's `162`, read the way FIDE's format defines it (and as
  # `Ainalrami.Trf` reads it): fixed 9-character entries, a symbol then the
  # value. W = a win (and a forfeit win, and the PAB unless P is given),
  # D = a draw (and the half-point bye), L = a loss, Z/A = the zero-point
  # bye and the forfeit loss, P = the pairing-allocated bye, X = unknown.
  defp point_values(text) do
    base = %{
      "1" => 1.0,
      "=" => 0.5,
      "0" => 0.0,
      "W" => 1.0,
      "D" => 0.5,
      "L" => 0.0,
      "+" => 1.0,
      "-" => 0.0,
      "F" => 1.0,
      "H" => 0.5,
      "Z" => 0.0,
      "U" => 1.0,
      "?" => 0.5
    }

    case header(text, "162") do
      nil ->
        base

      line ->
        entries =
          line
          |> String.graphemes()
          |> Enum.drop(1)
          |> Enum.chunk_every(9)
          |> Enum.map(&Enum.join/1)
          |> Enum.reject(&(String.trim(&1) == ""))
          |> Enum.map(fn e ->
            {String.slice(e, 0, 1), e |> String.slice(1, 4) |> String.trim() |> parse_float()}
          end)

        pinned_p? = Enum.any?(entries, &(elem(&1, 0) == "P"))

        Enum.reduce(entries, base, fn
          {_, nil}, acc ->
            acc

          {"W", v}, acc ->
            acc = Map.merge(acc, %{"1" => v, "W" => v, "+" => v, "F" => v})
            if pinned_p?, do: acc, else: Map.put(acc, "U", v)

          {"D", v}, acc ->
            Map.merge(acc, %{"=" => v, "D" => v, "H" => v})

          {"L", v}, acc ->
            Map.merge(acc, %{"0" => v, "L" => v})

          {k, v}, acc when k in ["Z", "A"] ->
            Map.merge(acc, %{"Z" => v, "-" => v})

          {"P", v}, acc ->
            Map.put(acc, "U", v)

          {"X", v}, acc ->
            Map.put(acc, "?", v)

          _, acc ->
            acc
        end)
    end
  end

  # A file for rating holds only records - as SWAR's accepted FIDE files do.
  defp check_only_records(st, tag, text) do
    lines = text |> String.split(["\r\n", "\n"]) |> Enum.reject(&(&1 == ""))

    cond do
      bad = Enum.find(lines, &(not Regex.match?(~r/^\d{3}( |$)/, &1))) ->
        fail(st, "#{tag}: a line that is not a record: #{inspect(bad)}")

      text =~ "###" or text =~ "DDD" ->
        fail(st, "#{tag}: a comment or legend line")

      Enum.any?(lines, &(String.starts_with?(&1, "162") and &1 =~ "X")) ->
        fail(st, "#{tag}: a 162 record with X")

      Enum.any?(lines, &(String.starts_with?(&1, "001") and &1 =~ "?")) ->
        fail(st, "#{tag}: an unknown result (?)")

      true ->
        bump(st, :only_records_ok)
    end
  end

  defp check_report(st, t, rounds, text, games, by_id) do
    st = bump(st, :files)
    st = check_only_records(st, "rounds #{inspect(rounds)}", text)

    st =
      case parse_ok(text) do
        :ok ->
          st

        {:error, e} ->
          fail(st, "rounds #{inspect(rounds)}: Ainalrami.Trf.parse refuses the sent file: #{e}")
      end

    rows = parse_001(text)
    rank_of = Map.new(Map.values(by_id), &{&1.id, &1.pairing_number})
    col_of = rounds |> Enum.with_index(1) |> Map.new()

    in_file = Enum.filter(games, &(&1.round in rounds))

    # 1. Every stored board is on both lines, right.
    {st, expected} =
      Enum.reduce(in_file, {st, MapSet.new()}, fn g, {acc, seen} ->
        col = Map.fetch!(col_of, g.round)

        cond do
          is_nil(g.black) ->
            # A pairing-allocated bye.
            b = get_in(rows, [rank_of[g.white], :blocks, col])

            if (b && b.opp == nil) and b.code == "U",
              do: {bump(acc, :byes_ok), MapSet.put(seen, {rank_of[g.white], col})},
              else:
                {fail(acc, "r#{g.round}: PAB of #{rank_of[g.white]} written as #{inspect(b)}"),
                 seen}

          g.finalised_open ->
            # Sent while postponed: not played in this file, for both
            # players. It is rated in a postponed-games file instead.
            wr = rank_of[g.white]
            br = rank_of[g.black]
            wb = get_in(rows, [wr, :blocks, col])
            bb = get_in(rows, [br, :blocks, col])
            not_played? = &(&1 != nil and &1.opp == nil and &1.code == "Z")

            acc =
              if not_played?.(wb) and not_played?.(bb),
                do: bump(acc, :postponed_not_played_ok),
                else:
                  fail(
                    acc,
                    "r#{g.round}: #{wr}-#{br} sent while postponed, expected 0000 - Z on " <>
                      "both lines, file has #{inspect(wb)} / #{inspect(bb)}"
                  )

            {acc, seen |> MapSet.put({wr, col}) |> MapSet.put({br, col})}

          true ->
            {wc, bc} = expected_codes(g)
            wr = rank_of[g.white]
            br = rank_of[g.black]
            wb = get_in(rows, [wr, :blocks, col])
            bb = get_in(rows, [br, :blocks, col])

            ok? =
              wb != nil and bb != nil and wb.opp == br and bb.opp == wr and wb.colour == "w" and
                bb.colour == "b" and wb.code == wc and bb.code == bc

            acc =
              if ok?,
                do: bump(acc, if(wc in @rated, do: :rated_games_ok, else: :other_games_ok)),
                else:
                  fail(
                    acc,
                    "r#{g.round}: #{wr}-#{br} #{g.result} (open? #{g.finalised_open}) expected " <>
                      "#{wc}/#{bc}, file has #{inspect(wb)} / #{inspect(bb)}"
                  )

            {acc, seen |> MapSet.put({wr, col}) |> MapSet.put({br, col})}
        end
      end)

    # 2. Nothing else carries an opponent or a played code.
    st =
      Enum.reduce(rows, st, fn {rank, row}, acc ->
        Enum.reduce(row.blocks, acc, fn {col, b}, acc2 ->
          cond do
            MapSet.member?(expected, {rank, col}) ->
              acc2

            b.opp != nil ->
              fail(
                acc2,
                "rank #{rank} col #{col}: a game the database does not hold: #{inspect(b)}"
              )

            b.code in ~w(1 0 = + - W D L ?) ->
              fail(acc2, "rank #{rank} col #{col}: played code with no game: #{inspect(b)}")

            true ->
              acc2
          end
        end)
      end)

    # 3. Mirror symmetry, read from the file alone.
    st =
      Enum.reduce(rows, st, fn {rank, row}, acc ->
        Enum.reduce(row.blocks, acc, fn {col, b}, acc2 ->
          with %{opp: opp} when opp != nil <- b,
               other when not is_nil(other) <- get_in(rows, [opp, :blocks, col]) do
            cond do
              other.opp != rank ->
                fail(acc2, "rank #{rank} col #{col}: opponent #{opp} does not point back")

              Map.get(@mirror, b.code) == other.code ->
                acc2

              {b.code, other.code} in @both_lose ->
                acc2

              {b.code, other.code} in [{"0", "0"}, {"=", "0"}, {"0", "="}] ->
                bump(acc2, :asymmetric_sides)

              true ->
                fail(acc2, "rank #{rank} col #{col}: #{b.code} against #{other.code}")
            end
          else
            _ -> acc2
          end
        end)
      end)

    # 4. Points add up from the file's own point system.
    values = point_values(text)

    st =
      Enum.reduce(rows, st, fn {rank, row}, acc ->
        sum =
          row.blocks
          |> Map.values()
          |> Enum.map(&Map.get(values, &1.code, 0.0))
          |> Enum.sum()

        if row.points != nil and abs(sum - row.points) < 0.001,
          do: acc,
          else:
            fail(
              acc,
              "rank #{rank}: points column #{inspect(row.points)}, its games add to #{sum}"
            )
      end)

    # 5. Headers.
    n_lines = map_size(rows)
    rated = Enum.count(rows, fn {_, r} -> r.rating not in ["", "0"] end)
    dates = (header(text, "132") || "") |> String.split(~r/\s+/, trim: true)

    st =
      cond do
        header(text, "062") |> to_string() |> String.trim() != "#{n_lines}" ->
          fail(st, "062 #{inspect(header(text, "062"))} but #{n_lines} player lines")

        header(text, "072") |> to_string() |> String.trim() != "#{rated}" ->
          fail(st, "072 #{inspect(header(text, "072"))} but #{rated} rated lines")

        length(dates) < length(rounds) ->
          fail(st, "132 has #{length(dates)} dates for #{length(rounds)} rounds")

        true ->
          bump(st, :headers_ok)
      end

    _ = t
    st
  end

  defp parse_ok(text) do
    case Ainalrami.Trf.parse(text) do
      {:error, e} -> {:error, inspect(e)}
      _ -> :ok
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # A game still open at the end fails `check_once/3`; one sent while open
  # is checked as not played above. Every other code is the table's.
  defp expected_codes(%{result: r}), do: Map.get(@codes, r, {"unexpected #{r}", "-"})

  defp check_late(st, text, n) do
    st = bump(st, :late_files)
    st = check_only_records(st, "postponed-games file", text)
    rows = parse_001(text)

    played =
      for {_rank, row} <- rows, {_c, b} <- row.blocks, b.opp != nil, reduce: 0 do
        acc -> acc + 1
      end

    st =
      case parse_ok(text) do
        :ok -> st
        {:error, e} -> fail(st, "late file refused by Ainalrami.Trf.parse: #{e}")
      end

    if div(played, 2) == n,
      do: bump(st, :late_games_in_files, n),
      else: fail(st, "late file carries #{div(played, 2)} games, the send recorded #{n}")
  end

  # Across every file sent for the tournament: each rated game once.
  defp check_once(st, games, by_id) do
    name = fn id -> Map.fetch!(by_id, id).name end

    from_reports =
      for {rounds, text} <- st.sent_files,
          rows = parse_001(text),
          names = Map.new(rows, fn {rank, row} -> {rank, row.name} end),
          {rank, row} <- rows,
          {col, b} <- row.blocks,
          b.colour == "w",
          b.opp != nil,
          b.code in (@rated ++ ~w(+ - W L D)) do
        {Enum.at(rounds, col - 1), names[rank], names[b.opp], b.code}
      end

    from_late =
      for {_p, text, _n} <- st.late_files,
          rows = parse_001(text),
          names = Map.new(rows, fn {rank, row} -> {rank, row.name} end),
          {rank, row} <- rows,
          {_col, b} <- row.blocks,
          b.colour == "w",
          b.opp != nil do
        {:late, names[rank], names[b.opp], b.code}
      end

    st =
      Enum.reduce(games, st, fn g, acc ->
        if g.black do
          {wc, _} = Map.get(@codes, g.result, {nil, nil})
          w = name.(g.white)
          b = name.(g.black)

          in_reports =
            Enum.count(from_reports, fn {round, ww, bb, _code} ->
              round == g.round and ww == w and bb == b
            end)

          cond do
            g.result in ["*", "*W", "*B"] ->
              fail(acc, "r#{g.round} #{w}-#{b} still open after the event")

            g.finalised_open ->
              if in_reports == 0,
                do: bump(acc, :late_not_in_reports),
                else:
                  fail(
                    acc,
                    "late game r#{g.round} #{w}-#{b} #{g.result}: also #{in_reports} time(s) in a round report"
                  )

            wc == nil ->
              acc

            true ->
              if in_reports == 1,
                do: bump(acc, :rated_once),
                else:
                  fail(
                    acc,
                    "r#{g.round} #{w}-#{b} #{g.result}: #{in_reports} times in round reports"
                  )
          end
        else
          acc
        end
      end)

    # The postponed-games files: per pair of players, exactly as many games
    # as that pair has games sent unplayed and played since - a pair can meet
    # twice when one meeting was a forfeit.
    pair = fn a, b -> Enum.sort([a, b]) end

    expected =
      games
      |> Enum.filter(&(&1.black && &1.finalised_open))
      |> Enum.frequencies_by(&pair.(name.(&1.white), name.(&1.black)))

    actual = Enum.frequencies_by(from_late, fn {_, w, b, _} -> pair.(w, b) end)

    if expected == actual,
      do: bump(st, :late_once, Enum.sum(Map.values(actual))),
      else:
        fail(
          st,
          "postponed-games files: expected per pair #{inspect(expected)}, files hold #{inspect(actual)}"
        )
  end

  # The engine dialect of the full report, round by round, against the file
  # the app actually handed its engine when it paired that round: every game
  # before the round and every score must be the same.
  defp check_against_engine_input(st, t, dump) do
    {:ok, full} = TrfExport.export(t, nil, dialect: :engine)
    exported = parse_001(full)

    Enum.reduce(1..st.rounds, st, fn r, acc ->
      case Process.get({:own_trf, r}) do
        nil ->
          acc

        own ->
          used = parse_001(own)

          diffs =
            for {rank, row} <- used,
                ex = Map.get(exported, rank),
                col <- 1..(r - 1)//1,
                a = Map.get(row.blocks, col),
                b = ex && Map.get(ex.blocks, col),
                a != b,
                # A game postponed when this round was paired went to the
                # engine as the draw it was then; played since, it differs.
                not (a.code == "=" and b.opp == a.opp and b.colour == a.colour),
                do: {rank, col, a, b}

          if diffs == [] do
            bump(acc, :engine_input_same)
          else
            if dump, do: File.write!(Path.join(dump, "s#{acc.seed}-engine-input-r#{r}.trf"), own)

            fail(
              acc,
              "round #{r}: export differs from the engine's input: #{inspect(Enum.take(diffs, 4))}"
            )
          end
      end
    end)
  end

  # Ainalrami's own checker on files for rating that start at round 1: the
  # first one sent (when it does), and one of every round as it stands at
  # the end - what a single Send of the whole event would hand out now.
  #
  # A game postponed and played later was paired around as the draw it then
  # was, and a game sent while postponed is not played in the file at all,
  # so neither can be replayed as it was paired: for a file holding one,
  # only the standings check must pass (the ranks follow the file's own
  # games and tie-breaks). Every other file must pass the whole check.
  defp check_with_engine(st, t, games, dump) do
    {:ok, full} = TrfExport.export(t, nil, for: :rating)
    paired = Pairing.paired_rounds_count(t.id)

    first =
      for {rounds, text} <- Enum.take(st.sent_files, 1),
          rounds == Enum.to_list(1..length(rounds)//1),
          rounds != Enum.to_list(1..paired//1),
          do: {"first-r1-#{length(rounds)}", rounds, text}

    full_rounds = Enum.to_list(1..paired//1)

    Enum.reduce(first ++ [{"full", full_rounds, full}], st, fn {tag, rounds, text}, acc ->
      postponed? =
        Enum.any?(
          games,
          &(&1.round in rounds and &1.black != nil and was_postponed?(&1, acc.dates))
        )

      acc = check_only_records(acc, "#{tag} rating file", text)
      run_checker(acc, tag, text, postponed?, dump)
    end)
  end

  # Postponed at some point: sent unplayed, or played on a later day than
  # its round (`play_late_games/2` dates a late game after its round; an
  # ordinary result is dated on the round's day).
  defp was_postponed?(g, dates),
    do: g.finalised_open or (g.played_on != nil and g.played_on != Enum.at(dates, g.round - 1))

  defp run_checker(st, tag, text, postponed?, dump) do
    path =
      Path.join(
        System.tmp_dir!(),
        "trfflow-#{st.seed}-#{tag}-#{System.unique_integer([:positive])}.trf"
      )

    File.write!(path, text)

    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        out =
          ExUnit.CaptureIO.capture_io(fn ->
            Process.put(:check_code, Ainalrami.CLI.run(["-c", path]))
          end)

        IO.write(:stderr, out)
      end)

    code = Process.get(:check_code)
    File.rm(path)

    standings_ok? =
      not (output =~ "do not follow") and not (output =~ "standings: cannot be checked")

    cond do
      not postponed? and code == 0 ->
        bump(st, :engine_check_ok)

      postponed? and standings_ok? ->
        bump(st, :engine_check_standings_ok)

      true ->
        if dump,
          do:
            File.write!(Path.join(dump, "s#{st.seed}-#{tag}-check.txt"), text <> "\n\n" <> output)

        fail(
          st,
          "ainalrami -c exit #{inspect(code)} on the #{tag} rating file" <>
            if(postponed?, do: " (standings check failed)", else: "")
        )
    end
  end
end
