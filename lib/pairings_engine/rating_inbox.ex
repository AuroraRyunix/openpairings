defmodule PairingsEngine.RatingInbox do
  @moduledoc """
  The rating period inbox: for each FIDE rating period (a calendar month,
  `PostponedGames.rating_period/1`), every tournament of this installation
  with something to say about it - what was sent for rating (the sent
  receipts, `PairingsEngine.SentReceipts`), what is missing (a finished
  round of a FIDE-rated tournament, dated in the period, with no receipt),
  and which postponed games are still open - and the deadline.

  ## Which tournaments are in it

  `listed?/2`: a tournament that has a sent receipt, or that is marked
  FIDE-rated (Settings, FIDE: `fide_homologated`, the one "this is rated"
  fact a tournament has - there is no national-rating flag, and
  `rating_method` only says which rating seeds the players). A tournament
  that merely exists and finished a round is nobody's rating business.

  A round "missing" and a rating list to make are said of FIDE-rated
  tournaments only (`rated?/1`). A club evening somebody once pressed Send
  on is listed with that receipt and nothing more: no receipt was ever
  owed for its other rounds.

  ## Which period a thing belongs to

    * a round's report: the month of the round's date (the tournament's
      `round_dates`), else the month it was sent;
    * a postponed-games file: its rating period, else the month it was sent;
    * a missing round or an open postponed game: the month of the round's
      date. A round with no date cannot be placed and is left out; the
      Dates page is where that is fixed.

  ## What it does not do

  It reads; it sends nothing and changes nothing. A receipt holds the exact
  file that was sent (`SentReceipts.file/1`), and that is what the inbox
  offers for download and what `check/1` checks - a postponed-games file
  included. A receipt from before files were kept has none; for a round's
  report the inbox then rebuilds a COPY from the tournament as it is now
  (`trf_copy/3`) and says so, and a postponed-games receipt has nothing to
  offer. A receipt that changed since it was sent is flagged by
  `SentReceipts.statuses/1`.
  """

  import Ecto.Query

  alias PairingsEngine.{PostponedGames, Repo, SentReceipts, TrfExport}
  alias PairingsEngine.Tournaments.{SentReceipt, Tournament}

  @doc """
  The periods, newest first, as `%{period:, level:, overdue?:,
  tournaments: [bucket]}`; a bucket is `%{tournament:, sent: [%{receipt:,
  changes:}], missing: [round number], open: [%{round:, pairing:}],
  report_list:, open_list:}`. The two lists are `list_status/2`'s answer
  (nil when there is no date to count from): `report_list` for the
  tournament's report (counted from the tournament's last day),
  `open_list` for the postponed-games file (counted from the last game's
  date). `level` is the worst `list_status/2` level among the things still
  to send in the period (`:normal` when nothing is); `overdue?` is
  `level != :normal`. `today` decides both. For a tournament that is not
  FIDE-rated `missing` is empty and both lists are nil.
  """
  def periods(today \\ Date.utc_today()) do
    receipts = Repo.all(from s in SentReceipt, select: s) |> Enum.group_by(& &1.tournament_id)

    tournaments =
      Repo.all(from t in Tournament, where: is_nil(t.deleted_at), order_by: [asc: t.name])

    tournaments
    |> Enum.filter(&listed?(&1, Map.get(receipts, &1.id, [])))
    |> Enum.flat_map(&facts(&1, Map.get(receipts, &1.id, [])))
    |> Enum.group_by(&elem(&1, 0), &Tuple.delete_at(&1, 0))
    |> Enum.map(fn {period, items} -> period(period, items, today) end)
    |> Enum.sort_by(&Date.to_gregorian_days(&1.period), :desc)
  end

  @doc """
  Whether `tournament` belongs in the inbox, given its sent receipts: it has
  one, or it is marked FIDE-rated.
  """
  def listed?(%Tournament{} = tournament, receipts) when is_list(receipts),
    do: receipts != [] or rated?(tournament)

  @doc """
  Whether `tournament` is meant to be rated, as far as it says so itself:
  the FIDE-rated tickbox on Settings, FIDE. Only such a tournament owes a
  report, so only it can have a round missing or a list to make.
  """
  def rated?(%Tournament{fide_homologated: rated}), do: rated == true

  # `{period, tournament, kind, data}` for everything a tournament has.
  defp facts(%Tournament{} = t, receipts) do
    sent =
      if receipts == [] do
        []
      else
        %{reports: reports, postponed: postponed} = SentReceipts.statuses(t.id)

        for status <- Map.values(reports) ++ postponed do
          {receipt_period(t, status.receipt), t, :sent, status}
        end
      end

    sent_rounds =
      for %SentReceipt{kind: "report", round: round} <- receipts, into: MapSet.new(), do: round

    missing =
      for %{state: :ready, round: round} <-
            (rated?(t) && PostponedGames.trf_round_states(t)) || [],
          not MapSet.member?(sent_rounds, round),
          period = round_period(t, round),
          do: {period, t, :missing, round}

    open =
      for %{round: round} = game <- PostponedGames.open_games(t),
          period = round_period(t, round),
          do: {period, t, :open, game}

    sent ++ missing ++ open
  end

  defp period(period, items, today) do
    tournaments =
      items
      |> Enum.group_by(fn {t, _kind, _data} -> t end)
      |> Enum.map(fn {t, rows} ->
        %{
          tournament: t,
          sent: for({_t, :sent, s} <- rows, do: s) |> Enum.sort_by(&sort_key/1),
          missing: for({_t, :missing, r} <- rows, do: r) |> Enum.sort(),
          open: for({_t, :open, g} <- rows, do: g)
        }
        |> with_lists(period, today)
      end)
      |> Enum.sort_by(&String.downcase(&1.tournament.name || ""))

    level =
      tournaments
      |> Enum.flat_map(fn b ->
        [b.missing != [] && b.report_list, b.open != [] && b.open_list]
      end)
      |> Enum.filter(& &1)
      |> Enum.map(& &1.level)
      |> Enum.max_by(&level_rank/1, &>=/2, fn -> :normal end)

    %{period: period, level: level, overdue?: level != :normal, tournaments: tournaments}
  end

  defp with_lists(%{tournament: t} = bucket, period, today) do
    report_list =
      with true <- rated?(t),
           {basis, %Date{} = day} <- report_day(t, period) do
        list_status(day, today, basis)
      else
        _ -> nil
      end

    open_list =
      with true <- rated?(t),
           %Date{} = day <- last_game_day(bucket) do
        list_status(day, today)
      else
        _ -> nil
      end

    Map.merge(bucket, %{report_list: report_list, open_list: open_list})
  end

  @doc """
  The day the report of `tournament`'s rounds in `period` (the first day of
  a month) is counted from, as `{:final, day}` or `{:interim, day}`; nil
  when the tournament has no date at all.

  A tournament of 30 days or fewer is reported once, counted from its last
  day (FIDE B.02 Art. 9.1). One lasting more than 30 days reports interim
  results every month (Art. 4.1), so its rounds of a month are counted from
  the last of them - `:interim` - except in the month it ends, which is the
  final report. Telling an October round of a club championship that it has
  until April was the previous arrangement, and it was wrong.

  Unless the tournament says it is not reported that way: a long event set
  to one report at the end (`Tournament.one_report_at_end?/1`) is
  registered with FIDE once, in its last month, and every period of it is
  `{:final, last}`, as if it had lasted a fortnight. FIDE takes games dated
  long before the registration, so October's rounds owe nothing until April.
  """
  def report_day(%Tournament{} = t, %Date{} = period) do
    last = tournament_last_day(t)

    cond do
      is_nil(last) ->
        nil

      Tournament.one_report_at_end?(t) or not long?(t, last) or
          Date.beginning_of_month(last) == period ->
        {:final, last}

      true ->
        in_period =
          for text <- t.round_dates || [],
              {:ok, d} <- [parse_date(text)],
              Date.beginning_of_month(d) == period,
              do: d

        case in_period do
          [] -> {:final, last}
          days -> {:interim, Enum.max(days, Date)}
        end
    end
  end

  # More than 30 days from the first day (the earliest round date, else the
  # start date) to the last: Art. 4.1's "lasting more than 30 days".
  defp long?(%Tournament{} = t, %Date{} = last) do
    dates =
      for text <- [t.start_date | t.round_dates || []], {:ok, d} <- [parse_date(text)], do: d

    case dates do
      [] -> false
      dates -> Date.diff(last, Enum.min(dates, Date)) > 30
    end
  end

  defp level_rank(:normal), do: 0
  defp level_rank(:later), do: 1
  defp level_rank(:late), do: 2

  # The date of the last postponed game still open in the bucket: the day
  # it was played, else its round's date.
  defp last_game_day(%{open: []}), do: nil

  defp last_game_day(%{tournament: t, open: open}) do
    open
    |> Enum.map(fn %{round: round, pairing: p} -> p.played_on || round_date(t, round) end)
    |> Enum.filter(&match?(%Date{}, &1))
    |> Enum.max(Date, fn -> nil end)
  end

  ## ---------- the list a tournament is rated in (FIDE B.02, Art. 9.1) ----------

  @doc """
  The tournament's last day: the latest of its round dates, else its end
  date; nil when it has no date at all.
  """
  def tournament_last_day(%Tournament{} = t) do
    dates =
      for text <- t.round_dates || [], {:ok, d} <- [parse_date(text)], do: d

    case dates do
      [] ->
        case parse_date(t.end_date) do
          {:ok, d} -> d
          _ -> nil
        end

      dates ->
        Enum.max(dates, Date)
    end
  end

  defp round_date(%Tournament{round_dates: dates}, round) when is_integer(round) do
    case parse_date(Enum.at(dates || [], round - 1)) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp round_date(_t, _round), do: nil

  defp parse_date(text) when is_binary(text), do: Date.from_iso8601(String.trim(text))
  defp parse_date(_), do: :error

  @doc """
  Where a report counted from `last_day` stands on `today`. `last_day` is a
  tournament's last day, the last game's day of a postponed-games file, or
  (`basis` `:interim`) the last round of a month of a tournament lasting
  more than 30 days.

  FIDE publishes a rating list on the first day of every month (B.02 Art.
  7.1). Art. 9.1 (2024): the report should be uploaded in time for the list
  after the month of `last_day` or, when five days or fewer remain from
  `last_day` to the end of that month, for the list one month later; a
  report not in time for the third list after the tournament ends is not
  rated. Art. 4.1 gives interim results "a monthly basis" and no day count,
  so an interim report borrows the same five days, and - not being the
  tournament report - is never called unrated, only overdue.

  Returns `%{basis:, list:, closes:, last_list:, last_chance:, level:,
  lands_in:}`:

    * `list` - the date of the list the report is for (a first of the
      month); `closes` the day before it, the date to have it uploaded by;
    * `last_list` - the date of the third list after `last_day`, and
      `last_chance` the day before it (both nil for `:interim`);
    * `level` - `:normal` (on or before `closes`), `:later` (past it;
      `lands_in` is the date of the next list it can still make) or `:late`
      (past `last_chance`: it will not be rated; `lands_in` nil).

  The third list is counted from the day the tournament ended, as the
  article says, not from the list it was due in: an event ending on the
  28th is due a month later than one ending on the 20th, and lost on the
  same day. Whether the Rating Officer's own cut-off is earlier than the
  eve of the list is the federation's business, as
  `PostponedGames.rating_period/1` says.
  """
  def list_status(%Date{} = last_day, %Date{} = today, basis \\ :final)
      when basis in [:final, :interim] do
    eom = Date.end_of_month(last_day)
    next = Date.add(eom, 1)

    list = if Date.diff(eom, last_day) <= 5, do: Date.shift(next, month: 1), else: next
    closes = Date.add(list, -1)

    last_list = if basis == :final, do: Date.shift(next, month: 2)
    last_chance = last_list && Date.add(last_list, -1)

    next_list = today |> Date.end_of_month() |> Date.add(1)

    {level, lands_in} =
      cond do
        Date.compare(today, closes) != :gt -> {:normal, list}
        is_nil(last_chance) or Date.compare(today, last_chance) != :gt -> {:later, next_list}
        true -> {:late, nil}
      end

    %{
      basis: basis,
      list: list,
      closes: closes,
      last_list: last_list,
      last_chance: last_chance,
      level: level,
      lands_in: lands_in
    }
  end

  defp sort_key(%{receipt: %{kind: kind, round: round, sent_at: at}}),
    do: {if(kind == "report", do: 0, else: 1), round || 0, DateTime.to_unix(at)}

  defp receipt_period(t, %SentReceipt{kind: "report", round: round} = receipt),
    do: round_period(t, round) || month(receipt.sent_at)

  defp receipt_period(_t, %SentReceipt{period: %Date{} = period}),
    do: Date.beginning_of_month(period)

  defp receipt_period(_t, %SentReceipt{} = receipt), do: month(receipt.sent_at)

  defp month(%DateTime{} = at), do: at |> DateTime.to_date() |> Date.beginning_of_month()

  defp round_period(%Tournament{round_dates: dates}, round) when is_integer(round) do
    with text when is_binary(text) <- Enum.at(dates || [], round - 1),
         {:ok, date} <- Date.from_iso8601(String.trim(text)) do
      Date.beginning_of_month(date)
    else
      _ -> nil
    end
  end

  defp round_period(_t, _round), do: nil

  ## ---------- the file, and its check ----------

  @doc """
  The file to offer for `receipt`: `{:ok, text, :sent}` - the exact file that
  was sent - when the receipt holds it, else (a report receipt from before
  files were kept) `{:ok, text, :copy}`, `trf_copy/3`'s rebuilt copy, for
  `scope` as there. The errors are `trf_copy/3`'s.
  """
  def file_for(%Tournament{} = t, %SentReceipt{} = receipt, scope) do
    case SentReceipts.file(receipt) do
      text when is_binary(text) ->
        {:ok, text, :sent}

      nil ->
        with {:ok, text} <- trf_copy(t, receipt, scope), do: {:ok, text, :copy}
    end
  end

  @doc """
  The TRF copy for `receipt` (a report receipt): `{:ok, text}` with `rounds`
  the round alone (`:round`) or every round up to it (`:through`, what a
  check needs, since a checker replays a round from the history before it).
  Not the file that was sent (`file_for/3` prefers that, when kept). A postponed-games
  receipt has no copy (`{:error, :no_copy}`): its games are marked sent and
  are no longer offered.
  """
  def trf_copy(%Tournament{}, %SentReceipt{kind: "postponed"}, _scope), do: {:error, :no_copy}

  def trf_copy(%Tournament{} = t, %SentReceipt{round: round}, scope) when is_integer(round) do
    spec = if scope == :through, do: "1-#{round}", else: Integer.to_string(round)

    case TrfExport.export(t, spec, copy: true) do
      {:ok, text} -> {:ok, text}
      {:error, %{message: message}} -> {:error, message}
      # FIDE mode, a postponed game open since (VCL4THP Q169): no TRF at all.
      {:error, {:open_postponed, _games}} -> {:error, :open_postponed}
    end
  end

  def trf_copy(_t, _receipt, _scope), do: {:error, :no_copy}

  @doc """
  Checks `text` (a TRF) with Ainalrami's checker, as `ainalrami -c` does:
  every round re-paired from the history before it, and the standings
  recomputed. Returns `%{status:, output:}`, `status` one of `:match`,
  `:differs`, `:not_replayed` (the file's pairing system is one the checker
  does not replay) or `:error`; `output` the checker's own trace.

  Runs in a process of its own with its output captured, since the checker
  keeps its trace level in the process it runs in. What the checker writes
  to the error stream (the detail of a round that differs) goes to the
  server log, not into `output`.
  """
  def check(text) when is_binary(text) do
    path = Path.join(System.tmp_dir!(), "rating-inbox-#{System.unique_integer([:positive])}.trf")
    File.write!(path, text)

    try do
      {:ok, io} = StringIO.open("")

      task =
        Task.async(fn ->
          Process.group_leader(self(), io)
          Ainalrami.CLI.run(["-c", path])
        end)

      code = Task.await(task, :timer.minutes(5))
      {:ok, {_input, output}} = StringIO.close(io)
      %{status: status(code), output: output}
    after
      File.rm(path)
    end
  end

  defp status(0), do: :match
  defp status(1), do: :differs
  defp status(2), do: :not_replayed
  defp status(_), do: :error
end
