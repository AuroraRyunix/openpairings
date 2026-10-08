defmodule PairingsEngine.RatingInbox do
  @moduledoc """
  The rating period inbox: for each FIDE rating period (a calendar month,
  `PostponedGames.rating_period/1`), every tournament of this installation
  with something to say about it - what was sent for rating (the sent
  receipts, `PairingsEngine.SentReceipts`), what is missing (a finished
  round of a FIDE-rated tournament, dated in the period, with no receipt),
  and which postponed games are still open - and the deadline.

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
  `level != :normal`. `today` decides both.
  """
  def periods(today \\ Date.utc_today()) do
    receipts = Repo.all(from s in SentReceipt, select: s) |> Enum.group_by(& &1.tournament_id)

    tournaments =
      Repo.all(from t in Tournament, where: is_nil(t.deleted_at), order_by: [asc: t.name])

    tournaments
    |> Enum.filter(&(Map.has_key?(receipts, &1.id) or &1.fide_homologated))
    |> Enum.flat_map(&facts(&1, Map.get(receipts, &1.id, [])))
    |> Enum.group_by(&elem(&1, 0), &Tuple.delete_at(&1, 0))
    |> Enum.map(fn {period, items} -> period(period, items, today) end)
    |> Enum.sort_by(&Date.to_gregorian_days(&1.period), :desc)
  end

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
      for %{state: :ready, round: round} <- PostponedGames.trf_round_states(t),
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
        |> with_lists(today)
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

  defp with_lists(bucket, today) do
    report_list =
      case tournament_last_day(bucket.tournament) do
        %Date{} = day -> list_status(day, today)
        nil -> nil
      end

    open_list =
      case last_game_day(bucket) do
        %Date{} = day -> list_status(day, today)
        nil -> nil
      end

    Map.merge(bucket, %{report_list: report_list, open_list: open_list})
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
  Where a report counted from `last_day` (a tournament's last day, or the
  last game's day of a postponed-games file) stands on `today`, under FIDE
  B.02 Art. 9.1 (2024): the report should reach the Rating Officer in time
  for the monthly list the tournament is registered in - the list of the
  month of `last_day` - or, when five days or fewer remain from `last_day`
  to the end of that month, the following month's list. A report that
  misses its list still goes to a later one, and is not rated only if it
  misses the third list counted from the target list (the target list and
  the two after it).

  Returns `%{target:, closes:, last_chance:, level:, lands_in:}`:

    * `target` - the first day of the target list's month; `closes` its
      last day (the date a report should be in by);
    * `last_chance` - the last day of the third list's month;
    * `level` - `:normal` (on or before `closes`), `:later` (past it, but
      it can still make the third list; `lands_in` is the first day of the
      month of the list it will now make) or `:late` (past `last_chance`:
      it will not be rated; `lands_in` nil).

  The monthly list is dated by the month it covers, as the rest of this
  page treats a rating period; whether the Rating Officer's own cut-off is
  earlier is the federation's business, as `PostponedGames.rating_period/1`
  says.
  """
  def list_status(%Date{} = last_day, %Date{} = today) do
    eom = Date.end_of_month(last_day)

    month =
      if Date.diff(eom, last_day) <= 5,
        do: Date.beginning_of_month(Date.add(eom, 1)),
        else: Date.beginning_of_month(last_day)

    closes = Date.end_of_month(month)
    last_chance = month |> Date.shift(month: 2) |> Date.end_of_month()

    {level, lands_in} =
      cond do
        Date.compare(today, closes) != :gt -> {:normal, month}
        Date.compare(today, last_chance) != :gt -> {:later, Date.beginning_of_month(today)}
        true -> {:late, nil}
      end

    %{target: month, closes: closes, last_chance: last_chance, level: level, lands_in: lands_in}
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
